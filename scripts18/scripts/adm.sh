#!/usr/bin/env bash
#============================================================
#  ADM - Gerenciador de builds para LFS / Sistema final
#
#  - Scripts de construção em:
#      $LFS/packages/<categoria>/<programa>/<programa>.sh
#      $LFS/packages/<categoria>/<programa>/<programa>.deps
#      $LFS/packages/<categoria>/<programa>/<programa>.pre_install
#      $LFS/packages/<categoria>/<programa>/<programa>.post_install
#      $LFS/packages/<categoria>/<programa>/<programa>.pre_uninstall
#      $LFS/packages/<categoria>/<programa>/<programa>.post_uninstall
#
#  - Resolve dependências (.deps)
#  - Gera meta + manifest em $LFS/var/adm
#  - Uninstall via manifest + hooks
#  - Retomada: já instalado => pula
#  - Chroot automático para pacotes "normais"
#    (cross-toolchain em .../cross/... é construído fora do chroot)
#
#  - update:
#      Usa helper opcional: $pkg_dir/$pkg.upstream
#      (script que imprime a última versão disponível no upstream)
#
#  - install:
#      Instala pacotes binários (.tar.zst/.tar.xz/.tar.gz/.tar)
#      gerados por você, e registra manifest/meta.
#
#  Configuração:
#    - Padrão: LFS=/mnt/lfs
#    - Opcional: /etc/adm.conf pode redefinir LFS, diretórios, etc.
#
#============================================================

set -euo pipefail

CMD_NAME="${0##*/}"
LFS_CONFIG="${LFS_CONFIG:-/etc/adm.conf}"

# LFS padrão se nada for definido
DEFAULT_LFS="${DEFAULT_LFS:-/mnt/lfs}"

# Variáveis globais (preenchidas em load_config)
LFS="${LFS:-}"
LFS_SOURCES_DIR=""
LFS_TOOLS_DIR=""
LFS_BUILD_SCRIPTS_DIR=""
LFS_LOG_DIR=""
ADM_DB_DIR=""
ADM_PKG_META_DIR=""
ADM_MANIFEST_DIR=""
ADM_STATE_DIR=""
ADM_LOG_FILE=""
ADM_BIN_PKG_DIR=""
CHROOT_FOR_BUILDS=1

ADM_DEP_STACK=""

#============================================================
# Utilitários básicos
#============================================================

die() {
    echo "[$CMD_NAME] ERRO: $*" >&2
    exit 1
}

adm_log() {
    local msg="$*"
    if [[ -n "${ADM_LOG_FILE:-}" ]]; then
        mkdir -p "$(dirname "$ADM_LOG_FILE")"
        printf '%s %s\n' "$(date +'%F %T')" "$msg" >> "$ADM_LOG_FILE"
    fi
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "este comando precisa ser executado como root"
    fi
}

usage() {
    cat <<EOF
Uso: $CMD_NAME <comando> [args...]

Comandos principais:
  status                      Mostra status e caminhos do LFS/ADM
  run-build <pkg>...          Constrói um ou mais pacotes (com dependências)
  list-installed              Lista pacotes registrados como instalados
  uninstall <pkg>             Desinstala um pacote via manifest + hooks
  verify [pkg...]             Verifica integridade de meta/manifest/arquivos

Pacotes binários:
  install <arquivo|nome>      Instala pacote binário (.tar.zst/.tar.xz/.tar.gz/.tar)
                              e registra no banco do ADM

Atualizações:
  update [pkg...]             Verifica upstream (via *.upstream) e gera relatório
                              de pacotes com nova versão

Chroot / LFS:
  mount                       Monta /dev,/proc,/sys,/run em \$LFS
  umount                      Desmonta /dev,/proc,/sys,/run de \$LFS
  chroot                      Monta, entra em chroot, desmonta ao sair

Observações:
  - LFS padrão: $DEFAULT_LFS
  - Você pode ajustar LFS e outros caminhos em: $LFS_CONFIG

  - Scripts de construção devem estar em:
      \$LFS/packages/<categoria>/<programa>/<programa>.sh

  - Dependências ficam em:
      \$LFS/packages/<categoria>/<programa>/<programa>.deps
    (um pacote por linha, # para comentário)

  - Para 'update', cada pacote pode ter um helper opcional:
      \$LFS/packages/<categoria>/<programa>/<programa>.upstream
    que deve imprimir a última versão disponível (ex: 5.2.32)
EOF
}

#============================================================
# Configuração / DB
#============================================================

load_config() {
    if [[ -f "$LFS_CONFIG" ]]; then
        # shellcheck source=/dev/null
        . "$LFS_CONFIG"
    fi

    # Se ainda não há LFS definido, usa padrão
    if [[ -z "${LFS:-}" ]]; then
        LFS="$DEFAULT_LFS"
    fi

    # Diretórios derivados com defaults sensatos
    LFS_SOURCES_DIR="${LFS_SOURCES_DIR:-$LFS/sources}"
    LFS_TOOLS_DIR="${LFS_TOOLS_DIR:-$LFS/tools}"
    LFS_BUILD_SCRIPTS_DIR="${LFS_BUILD_SCRIPTS_DIR:-$LFS/packages}"
    LFS_LOG_DIR="${LFS_LOG_DIR:-$LFS/logs}"

    ADM_DB_DIR="${ADM_DB_DIR:-$LFS/var/adm}"
    ADM_PKG_META_DIR="$ADM_DB_DIR/pkgs"
    ADM_MANIFEST_DIR="$ADM_DB_DIR/manifests"
    ADM_STATE_DIR="$ADM_DB_DIR/state"
    ADM_LOG_FILE="$ADM_DB_DIR/adm.log"

    # Diretório padrão onde ficam pacotes binários prontos
    ADM_BIN_PKG_DIR="${ADM_BIN_PKG_DIR:-$LFS/binary-packages}"

    # Diretório de perfis (env) para controlar modo de build (glibc/musl, pass1/final, etc.)
    ADM_PROFILE_DIR="${ADM_PROFILE_DIR:-$LFS/profiles}"

    CHROOT_FOR_BUILDS="${CHROOT_FOR_BUILDS:-1}"

    # Exporta LFS e alguns caminhos chave para scripts de build
    export LFS LFS_SOURCES_DIR LFS_TOOLS_DIR
}

adm_ensure_db() {
    mkdir -p "$ADM_PKG_META_DIR" "$ADM_MANIFEST_DIR" "$ADM_STATE_DIR" "$LFS_LOG_DIR" "$ADM_BIN_PKG_DIR"
}

#============================================================
# Montagem e chroot
#============================================================

mount_virtual_fs() {
    echo ">> Montando sistemas de arquivos virtuais em $LFS ..."

    mkdir -p "$LFS/dev" "$LFS/dev/pts" "$LFS/proc" "$LFS/sys" "$LFS/run"

    if ! mountpoint -q "$LFS/dev"; then
        mount --bind /dev "$LFS/dev"
        echo "  - /dev montado."
    fi
    if ! mountpoint -q "$LFS/dev/pts"; then
        mount -t devpts devpts "$LFS/dev/pts" -o gid=5,mode=620
        echo "  - /dev/pts montado."
    fi
    if ! mountpoint -q "$LFS/proc"; then
        mount -t proc proc "$LFS/proc"
        echo "  - /proc montado."
    fi
    if ! mountpoint -q "$LFS/sys"; then
        mount -t sysfs sysfs "$LFS/sys"
        echo "  - /sys montado."
    fi
    if ! mountpoint -q "$LFS/run"; then
        mount -t tmpfs tmpfs "$LFS/run"
        echo "  - /run montado."
    fi

    echo ">> Sistemas de arquivos virtuais montados."
}

umount_virtual_fs() {
    echo ">> Desmontando sistemas de arquivos virtuais de $LFS ..."
    local mp
    for mp in "$LFS/run" "$LFS/proc" "$LFS/sys" "$LFS/dev/pts" "$LFS/dev"; do
        if mountpoint -q "$mp"; then
            if ! umount "$mp"; then
                echo "  ! Não foi possível desmontar $mp (talvez esteja em uso)" >&2
            else
                echo "  - $mp desmontado."
            fi
        fi
    done
    echo ">> Desmontagem concluída."
}

enter_chroot_shell() {
    if [[ ! -d "$LFS" ]]; then
        die "Diretório LFS não existe: $LFS"
    fi

    chroot "$LFS" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PS1="[LFS chroot] \\u:\\w\\$ " \
        PATH=/usr/bin:/usr/sbin:/bin:/sbin \
        LFS="/" \
        /bin/bash --login
}

cmd_chroot() {
    require_root
    mount_virtual_fs
    echo ">> Entrando em chroot em $LFS ..."
    enter_chroot_shell || {
        umount_virtual_fs
        die "Falha ao entrar em chroot."
    }
    echo ">> Saindo do chroot, desmontando ..."
    umount_virtual_fs
}

#============================================================
# Snapshot / Manifest
#============================================================

snapshot_fs() {
    local outfile="$1"

    if [[ -z "${LFS:-}" || ! -d "$LFS" ]]; then
        echo "snapshot_fs: diretório LFS inválido: ${LFS:-<não definido>}" >&2
        return 1
    fi

    # Garante diretório do arquivo de saída
    mkdir -p "$(dirname "$outfile")"

    # find dentro de $LFS, sem atravessar para outros devices (-xdev),
    # podando diretórios internos que não devem entrar no snapshot.
    find "$LFS" -xdev \
        \(  -path "$ADM_DB_DIR" \
         -o -path "$LFS_BUILD_SCRIPTS_DIR" \
         -o -path "$LFS_SOURCES_DIR" \
         -o -path "$LFS_LOG_DIR" \
         -o -path "${ADM_BIN_PKG_DIR:-$LFS/binary-packages}" \
         -o -path "${ADM_PROFILE_DIR:-$LFS/profiles}" \) -prune -o \
        \( -type f -o -type l -o -type d \) -print \
        | LC_ALL=C sort > "$outfile"
}

#============================================================
#  Manifest generate from snapshots
#============================================================

generate_manifest_from_snapshots() {
    local pre_snapshot="$1"
    local post_snapshot="$2"
    local manifest="$3"

    if [[ ! -f "$pre_snapshot" || ! -f "$post_snapshot" ]]; then
        echo "generate_manifest_from_snapshots: snapshots inexistentes: $pre_snapshot / $post_snapshot" >&2
        return 1
    fi

    local tmp_created
    tmp_created="$(mktemp "${ADM_STATE_DIR:-/tmp}/created.XXXXXX")"

    # Paths que existem só no snapshot final (novos)
    LC_ALL=C comm -13 "$pre_snapshot" "$post_snapshot" > "$tmp_created"

    : > "$manifest"

    local path type
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue

        # Determina tipo atual do caminho
        if [[ -L "$path" ]]; then
            type="L"
        elif [[ -d "$path" ]]; then
            type="D"
        elif [[ -f "$path" ]]; then
            type="F"
        else
            # Tipo desconhecido, ainda assim registra com '?'
            type="?"
        fi

        printf '%s %s\n' "$type" "$path" >> "$manifest"
    done < "$tmp_created"

    rm -f "$tmp_created"
}

#============================================================
# Localização de scripts / hooks / deps
#============================================================

find_build_script() {
    local pkg="$1"
    local matches=()
    local roots=()

    # 1) Se ADM_LIBC estiver setado, prioriza a categoria libc-<flavor>
    #    Ex.: ADM_LIBC=musl --> base/libc-musl/<pkg>/<pkg>.sh
    if [[ -n "${ADM_LIBC:-}" ]]; then
        roots+=( "$LFS_BUILD_SCRIPTS_DIR/libc-${ADM_LIBC}" )
    fi

    # 2) Raiz padrão (permite manter scripts antigos, ex.: $LFS/packages/base/...)
    roots+=( "$LFS_BUILD_SCRIPTS_DIR" )

    shopt -s nullglob
    for root in "${roots[@]}"; do
        matches+=( "$root"/*/"$pkg"/"$pkg".sh )
    done
    shopt -u nullglob

    # Remove duplicados (se algum path apareceu duas vezes)
    if (( ${#matches[@]} > 1 )); then
        local uniq=() seen
        declare -A seen=()
        local m
        for m in "${matches[@]}"; do
            [[ -n "${seen[$m]:-}" ]] && continue
            uniq+=( "$m" )
            seen["$m"]=1
        done
        matches=("${uniq[@]}")
    fi

    if (( ${#matches[@]} == 0 )); then
        die "Script de build não encontrado para pacote '$pkg' (roots: ${roots[*]})"
    elif (( ${#matches[@]} > 1 )); then
        echo "Foram encontrados múltiplos scripts para '$pkg':" >&2
        printf '  - %s\n' "${matches[@]}" >&2
        die "Ambiguidade: mais de um script de build para '$pkg'."
    fi

    printf '%s\n' "${matches[0]}"
}

pkg_dir_from_script() {
    local script="$1"
    dirname "$script"
}

hook_path() {
    local pkg_dir="$1"
    local pkg="$2"
    local hook_type="$3" # pre_install, post_install, pre_uninstall, post_uninstall
    echo "$pkg_dir/${pkg}.${hook_type}"
}

# Executa hook no host (fora do chroot)
# Comportamento:
#   - Se o hook não existir ou não for executável, não faz nada.
#   - Se o hook falhar:
#       - Faz log e mostra aviso.
#       - Se ADM_STRICT_HOOKS=1, PROPAGA o erro (faz o build/uninstall falhar).
#       - Caso contrário, ignora o erro (retorna 0).
run_hook_host() {
    local hook="$1"
    local phase="$2"
    local pkg="$3"

    if [[ -x "$hook" ]]; then
        echo ">> [$pkg] Executando hook $phase: $(basename "$hook")"
        adm_log "HOOK $phase $pkg $hook"

        local rc=0
        if ! ADM_HOOK_PHASE="$phase" ADM_HOOK_PKG="$pkg" ADM_HOOK_MODE="host" \
             "$hook"; then
            rc=$?
            echo "!! [$pkg] Hook $phase falhou (rc=$rc): $(basename "$hook")" >&2
            adm_log "HOOK_FAIL $phase $pkg $hook RC=$rc"
            if [[ "${ADM_STRICT_HOOKS:-0}" -eq 1 ]]; then
                return "$rc"
            fi
        else
            adm_log "HOOK_OK $phase $pkg $hook"
        fi
    fi

    return 0
}

# Executa hook dentro do chroot
# Mesma lógica de falha de run_hook_host, mas usando chroot_exec_file.
run_hook_chroot() {
    local hook="$1"
    local phase="$2"
    local pkg="$3"

    if [[ -x "$hook" ]]; then
        echo ">> [$pkg] Executando hook (chroot) $phase: $(basename "$hook")"
        adm_log "HOOK_CHROOT $phase $pkg $hook"

        local rc=0
        if ! ADM_HOOK_PHASE="$phase" ADM_HOOK_PKG="$pkg" ADM_HOOK_MODE="chroot" \
             chroot_exec_file "$hook"; then
            rc=$?
            echo "!! [$pkg] Hook (chroot) $phase falhou (rc=$rc): $(basename "$hook")" >&2
            adm_log "HOOK_CHROOT_FAIL $phase $pkg $hook RC=$rc"
            if [[ "${ADM_STRICT_HOOKS:-0}" -eq 1 ]]; then
                return "$rc"
            fi
        else
            adm_log "HOOK_CHROOT_OK $phase $pkg $hook"
        fi
    fi

    return 0
}

#============================================================
# Chroot helper (ajustado para passar variáveis dos hooks)
#============================================================
chroot_exec_file() {
    local abs="$1"
    local rel="${abs#$LFS}"

    if [[ "$rel" == "$abs" ]]; then
        die "Arquivo $abs não está dentro de LFS ($LFS)"
    fi

    rel="${rel#/}"

    # Ambiente mínimo e previsível
    local env_args=(
        HOME=/root
        TERM="${TERM:-xterm}"
        PATH=/usr/bin:/usr/sbin:/bin:/sbin
        LFS="/"
    )

    # Propaga variáveis de contexto de hook, se existirem
    if [[ -n "${ADM_HOOK_PHASE:-}" ]]; then
        env_args+=("ADM_HOOK_PHASE=$ADM_HOOK_PHASE")
    fi
    if [[ -n "${ADM_HOOK_PKG:-}" ]]; then
        env_args+=("ADM_HOOK_PKG=$ADM_HOOK_PKG")
    fi
    if [[ -n "${ADM_HOOK_MODE:-}" ]]; then
        env_args+=("ADM_HOOK_MODE=$ADM_HOOK_MODE")
    fi

    chroot "$LFS" /usr/bin/env -i "${env_args[@]}" \
        /bin/bash -lc "/$rel"
}

read_deps() {
    local pkg="$1"
    local script dir deps_file

    script="$(find_build_script "$pkg")"
    dir="$(pkg_dir_from_script "$script")"
    deps_file="$dir/$pkg.deps"

    if [[ ! -f "$deps_file" ]]; then
        echo ""
        return 0
    fi

    local deps=()
    local line
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        deps+=("$line")
    done <"$deps_file"

    printf '%s\n' "${deps[@]}"
}

is_cross_script() {
    local script="$1"
    [[ "$script" == *"/cross/"* ]]
}

#============================================================
# META helpers (inclui VERSION) e leitura
#============================================================

write_meta() {
    local pkg="$1"
    local script="$2"
    local deps="$3"

    local meta pkg_dir version_file version
    meta="$(pkg_meta_file "$pkg")"
    pkg_dir="$(pkg_dir_from_script "$script")"
    version_file="$pkg_dir/$pkg.version"
    version=""

    if [[ -f "$version_file" ]]; then
        version="$(<"$version_file")"
    fi

    cat >"$meta" <<EOF
NAME="$pkg"
SCRIPT="$script"
BUILT_AT="$(date +'%F %T')"
DEPS="$deps"
STATUS="installed"
VERSION="$version"
EOF
}

write_meta_binary() {
    local pkg="$1"
    local version="$2"
    local tarball="$3"

    local meta
    meta="$(pkg_meta_file "$pkg")"

    cat >"$meta" <<EOF
NAME="$pkg"
SCRIPT="binary:$tarball"
BUILT_AT="$(date +'%F %T')"
DEPS=""
STATUS="installed"
VERSION="$version"
EOF
}

read_meta_field() {
    local pkg="$1"
    local key="$2"
    local meta k v

    meta="$(pkg_meta_file "$pkg")"
    [[ -f "$meta" ]] || return 1

    # Parser simples de KEY="value", sem usar source nem eval.
    # Assume o formato gerado por write_meta/write_meta_binary.
    while IFS='=' read -r k v; do
        # Ignora linhas vazias ou comentários
        [[ -z "$k" || "$k" == \#* ]] && continue

        # Remove espaços em volta da chave
        # (ex.: '  NAME  ' -> 'NAME')
        k="${k#"${k%%[![:space:]]*}"}"   # trim left
        k="${k%"${k##*[![:space:]]}"}"   # trim right

        [[ "$k" == "$key" ]] || continue

        # Remove espaços iniciais do valor
        v="${v#"${v%%[![:space:]]*}"}"

        # Se o valor estiver entre aspas duplas, remove o par externo
        if [[ "$v" == \"*\" ]]; then
            v="${v#\"}"   # tira primeira aspas
            v="${v%\"}"   # tira última aspas
        fi

        printf '%s\n' "$v"
        return 0
    done < "$meta"

    # Se chegou aqui, não encontrou a chave
    return 1
}

get_installed_version() {
    local pkg="$1"
    local ver
    ver="$(read_meta_field "$pkg" VERSION 2>/dev/null || true)"
    echo "$ver"
}

#============================================================
# Build de um pacote (com snapshot / manifest / hooks)
#============================================================

run_single_build() {
    local pkg="$1"

    adm_ensure_db

    local script
    script="$(find_build_script "$pkg")" || return 1
    local pkg_dir
    pkg_dir="$(dirname "$script")"

    mkdir -p "$LFS_LOG_DIR"
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local logfile="$LFS_LOG_DIR/${pkg}-${ts}.log"

    mkdir -p "$ADM_STATE_DIR"
    local pre_snap post_snap manifest
    pre_snap="$ADM_STATE_DIR/${pkg}.pre.$ts.snapshot"
    post_snap="$ADM_STATE_DIR/${pkg}.post.$ts.snapshot"
    manifest="$(pkg_manifest_file "$pkg")"

    local use_chroot=0
    local mounted=0

    # Decide se usa chroot: scripts em /cross/ rodam fora,
    # demais, se LFS != "/", rodam em chroot (se CHROOT_FOR_BUILDS=1).
    if is_cross_script "$script"; then
        use_chroot=0
    else
        if [[ "${CHROOT_FOR_BUILDS:-1}" -eq 1 && "${LFS:-/}" != "/" ]]; then
            use_chroot=1
        fi
    fi

    if (( use_chroot )); then
        require_root
    fi

    # Snapshot antes do build
    snapshot_fs "$pre_snap"

    {
        echo "=== Build do pacote: $pkg ==="
        echo "Script de build: $script"
        echo "Diretório do pacote: $pkg_dir"
        echo "Início: $(date)"

        local pre_install post_install
        pre_install="$pkg_dir/pre_install"
        post_install="$pkg_dir/post_install"

        if (( use_chroot )); then
            echo "Executando build em chroot em $LFS"
            mount_virtual_fs
            mounted=1

            if [[ -x "$pre_install" ]]; then
                echo "Rodando hook pre_install em chroot"
                chroot_exec_file "$pre_install"
            fi

            echo "Rodando script de build em chroot"
            chroot_exec_file "$script"

            if [[ -x "$post_install" ]]; then
                echo "Rodando hook post_install em chroot"
                chroot_exec_file "$post_install"
            fi
        else
            echo "Executando build no host (sem chroot)"
            if [[ -x "$pre_install" ]]; then
                echo "Rodando hook pre_install no host"
                "$pre_install"
            fi

            echo "Rodando script de build no host"
            "$script"

            if [[ -x "$post_install" ]]; then
                echo "Rodando hook post_install no host"
                "$post_install"
            fi
        fi

        echo "Build finalizado: $(date)"
    } >"$logfile" 2>&1 || {
        local rc=$?
        if (( mounted )); then
            umount_virtual_fs || true
        fi
        echo "Erro ao construir pacote '$pkg'. Veja o log em: $logfile" >&2
        return "$rc"
    }

    if (( mounted )); then
        umount_virtual_fs || true
    fi

    # Snapshot depois do build
    snapshot_fs "$post_snap"

    # Gera manifest com tipos (F/L/D)
    generate_manifest_from_snapshots "$pre_snap" "$post_snap" "$manifest"

    rm -f "$pre_snap" "$post_snap"

    # Lê deps para gravar meta
    local deps
    deps="$(read_deps "$pkg" || true)"

    write_meta "$pkg" "$script" "$deps"

    echo "Pacote '$pkg' construído com sucesso. Log: $logfile"
}

load_profile() {
    if [[ -z "${ADM_PROFILE:-}" ]]; then
        return 0
    fi

    local pf="${ADM_PROFILE_DIR}/${ADM_PROFILE}.env"
    if [[ ! -f "$pf" ]]; then
        die "Perfil ADM_PROFILE='${ADM_PROFILE}' não encontrado em ${ADM_PROFILE_DIR}"
    fi

    echo "==> [adm] Carregando perfil: ${ADM_PROFILE} (${pf})"
    # shellcheck source=/dev/null
    . "$pf"
}

#============================================================
# Build com dependências e retomada
#============================================================

build_with_deps() {
    local pkg="$1"

    if is_installed "$pkg"; then
        echo ">> [$pkg] Já instalado, pulando."
        adm_log "SKIP INSTALLED $pkg"
        return 0
    fi

    local deps dep
    deps=()
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        deps+=("$dep")
    done < <(read_deps "$pkg" || true)

    if [[ " $ADM_DEP_STACK " == *" $pkg "* ]]; then
        die "Detectado ciclo de dependências envolvendo '$pkg' (stack: $ADM_DEP_STACK)"
    fi

    local old_stack="$ADM_DEP_STACK"
    ADM_DEP_STACK="$ADM_DEP_STACK $pkg"

    for dep in "${deps[@]}"; do
        echo ">> [$pkg] Dependência: $dep"
        build_with_deps "$dep"
    done

    run_single_build "$pkg"

    ADM_DEP_STACK="$old_stack"
}

cmd_run_build() {
    if [[ $# -lt 1 ]]; then
        die "Uso: $CMD_NAME run-build <pacote> [outros pacotes...]"
    fi

    adm_ensure_db

    # Carrega o perfil (se ADM_PROFILE estiver definido), antes de qualquer build
    load_profile

    local pkg
    for pkg in "$@"; do
        build_with_deps "$pkg"
    done
}

#============================================================
# Uninstall
#============================================================

uninstall_pkg() {
    local pkg="$1"

    adm_ensure_db
    require_root

    local manifest meta
    manifest="$(pkg_manifest_file "$pkg")"
    meta="$(pkg_meta_file "$pkg")"

    if [[ ! -f "$manifest" ]]; then
        echo "uninstall_pkg: manifest não encontrado para pacote '$pkg': $manifest" >&2
        return 1
    fi
    if [[ ! -f "$meta" ]]; then
        echo "uninstall_pkg: meta não encontrado para pacote '$pkg': $meta" >&2
        return 1
    fi

    if ! command -v tac >/dev/null 2>&1; then
        echo "uninstall_pkg: 'tac' é necessário para desinstalar (não encontrado no PATH)" >&2
        return 1
    fi

    # Verifica dependências reversas (outros pacotes que dependem deste)
    local other_meta other_pkg deps rev_deps=()
    for other_meta in "$ADM_PKG_META_DIR"/*.meta; do
        [[ -f "$other_meta" ]] || continue
        other_pkg="$(basename "${other_meta%.meta}")"
        [[ "$other_pkg" == "$pkg" ]] && continue

        deps="$(read_meta_field "$other_pkg" "DEPS" || true)"
        # compara por palavra
        if [[ " $deps " == *" $pkg "* ]]; then
            rev_deps+=("$other_pkg")
        fi
    done

    if (( ${#rev_deps[@]} > 0 )) && [[ "${ADM_ALLOW_BROKEN_DEPS:-0}" != "1" ]]; then
        echo "uninstall_pkg: não é seguro remover '$pkg'." >&2
        echo "Os seguintes pacotes dependem dele:" >&2
        local rp
        for rp in "${rev_deps[@]}"; do
            echo "  - $rp" >&2
        done
        echo "Se quiser realmente remover mesmo assim, defina ADM_ALLOW_BROKEN_DEPS=1 no ambiente." >&2
        return 1
    fi

    # Hooks de pre/post-uninstall
    local script pkg_dir pre_uninstall post_uninstall
    script="$(read_meta_field "$pkg" "SCRIPT" || true)"

    if [[ -n "$script" && -f "$script" ]]; then
        pkg_dir="$(dirname "$script")"
        pre_uninstall="$pkg_dir/pre_uninstall"
        post_uninstall="$pkg_dir/post_uninstall"

        if [[ -x "$pre_uninstall" ]]; then
            echo "Rodando hook pre_uninstall para '$pkg'"
            "$pre_uninstall"
        fi
    fi

    echo "Removendo arquivos do pacote '$pkg' de acordo com manifest: $manifest"

    # Lê manifest de trás pra frente com tac:
    # - Formato novo: "T /caminho"
    # - Formato antigo: "/caminho"
    tac "$manifest" | while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue

        local type path
        if [[ "$entry" == [FDL?]" "* ]]; then
            type="${entry%% *}"
            path="${entry#* }"
        else
            type=""
            path="$entry"
        fi

        # Normaliza espaços
        path="${path#"${path%%[![:space:]]*}"}"
        path="${path%"${path##*[![:space:]]}"}"

        [[ -z "$path" ]] && continue

        # Segurança: caminho tem que estar dentro de $LFS
        if [[ "$path" != "$LFS" && "$path" != "$LFS"/* ]]; then
            echo "Aviso: ignorando caminho fora de \$LFS no manifest: $path" >&2
            continue
        fi

        # Segurança: não permitir '..' nos segmentos
        if [[ "$path" == *"/../"* || "$path" == "../"* || "$path" == *"/.." ]]; then
            echo "Aviso: ignorando caminho suspeito com '..' no manifest: $path" >&2
            continue
        fi

        # Remove conforme tipo
        if [[ -f "$path" || -L "$path" ]]; then
            rm -f -- "$path" || echo "Falha ao remover arquivo/link: $path" >&2
        elif [[ -d "$path" ]]; then
            # Diretório: tenta remover, mas ignora erro se não vazio
            rmdir -- "$path" 2>/dev/null || true
        else
            # Se já não existe, ignore
            :
        fi
    done

    # Remove manifest e meta
    rm -f -- "$manifest" "$meta"

    if [[ -n "$post_uninstall" && -x "$post_uninstall" ]]; then
        echo "Rodando hook post_uninstall para '$pkg'"
        "$post_uninstall"
    fi

    echo "Pacote '$pkg' desinstalado."
}

cmd_uninstall() {
    uninstall_pkg "${1:-}"
}

#============================================================
# INSTALL de pacotes binários (.tar.*)
#============================================================

extract_tarball_into_lfs() {
    local tarball="$1"

    if [[ ! -f "$tarball" ]]; then
        die "Pacote binário não encontrado: $tarball"
    fi

    case "$tarball" in
        *.tar.zst)
            zstd -d -c "$tarball" | tar -xf - -C "$LFS"
            ;;
        *.tar.xz)
            xz -d -c "$tarball" | tar -xf - -C "$LFS"
            ;;
        *.tar.gz|*.tgz)
            gzip -d -c "$tarball" | tar -xf - -C "$LFS"
            ;;
        *.tar)
            tar -xf "$tarball" -C "$LFS"
            ;;
        *)
            die "Formato de pacote não suportado: $tarball (use .tar.zst/.tar.xz/.tar.gz/.tar)"
            ;;
    esac
}

parse_pkg_from_tarball() {
    local tarball="$1"
    local base pkg version arch name_ver

    base="$(basename "$tarball")"
    base="${base%%.tar.zst}"
    base="${base%%.tar.xz}"
    base="${base%%.tar.gz}"
    base="${base%%.tgz}"
    base="${base%%.tar}"

    # Tenta detectar arquitetura apenas se for um sufixo "conhecido"
    arch=""
    name_ver="$base"

    local known_arches=(
        x86_64 aarch64 arm64 i486 i586 i686
        armv7 armv7l riscv64 ppc64le s390x
    )

    local a
    for a in "${known_arches[@]}"; do
        if [[ "$base" == *"-${a}" ]]; then
            arch="$a"
            name_ver="${base%-*}"
            break
        fi
    done

    # Se não detectar arch, name_ver continua igual a base
    if [[ -z "$arch" ]]; then
        name_ver="$base"
    fi

    # Agora precisamos separar nome e versão dentro de name_ver.
    # Estratégia:
    #   - Split em partes por '-'
    #   - A primeira parte que COMEÇA com dígito marca o início da versão
    #   - Tudo que vem antes é o nome do pacote (podendo conter '-')
    #   - Tudo que vem a partir dali é a versão (podendo conter '-')
    pkg=""
    version=""

    # Se não há '-', não dá pra separar nome/versão com essa heurística
    if [[ "$name_ver" != *"-"* ]]; then
        pkg="$name_ver"
        version=""
        printf '%s\n' "$pkg" "$version"
        return 0
    fi

    local IFS='-'
    read -r -a parts <<< "$name_ver"
    IFS=$' \t\n'

    local i found_ver=0
    for i in "${!parts[@]}"; do
        if [[ "${parts[i]}" =~ ^[0-9] ]]; then
            # Encontramos o início de algo que parece versão
            found_ver=1
            break
        fi
    done

    if (( found_ver == 1 && i > 0 )); then
        # Monta o nome do pacote com as partes antes da primeira parte "numérica"
        local j
        for (( j = 0; j < i; j++ )); do
            if (( j == 0 )); then
                pkg="${parts[j]}"
            else
                pkg+="-${parts[j]}"
            fi
        done

        # Monta a versão com as partes a partir da primeira parte "numérica"
        version="${parts[i]}"
        for (( j = i + 1; j < ${#parts[@]}; j++ )); do
            version+="-${parts[j]}"
        done
    else
        # Não encontramos um pedaço que pareça versão (começando com dígito),
        # então consideramos que não há versão separada.
        pkg="$name_ver"
        version=""
    fi

    printf '%s\n' "$pkg" "$version"
}

install_binary_pkg() {
    local tarball="$1"

    require_root
    adm_ensure_db

    if [[ ! -f "$tarball" ]]; then
        echo "install_binary_pkg: arquivo não encontrado: $tarball" >&2
        return 1
    fi

    local pkg version
    read -r pkg version < <(parse_pkg_from_tarball "$tarball")

    if [[ -z "$pkg" ]]; then
        echo "install_binary_pkg: não foi possível determinar nome do pacote a partir de $tarball" >&2
        return 1
    fi

    mkdir -p "$ADM_STATE_DIR"

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"

    local pre_snap post_snap manifest
    pre_snap="$ADM_STATE_DIR/${pkg}.prebin.$ts.snapshot"
    post_snap="$ADM_STATE_DIR/${pkg}.postbin.$ts.snapshot"
    manifest="$(pkg_manifest_file "$pkg")"

    snapshot_fs "$pre_snap"

    echo "Instalando pacote binário '$pkg' a partir de: $tarball"

    case "$tarball" in
        *.tar.zst)
            zstd -d < "$tarball" | tar -C "$LFS" -xvf -
            ;;
        *.tar.xz)
            xz -d < "$tarball" | tar -C "$LFS" -xvf -
            ;;
        *.tar.gz|*.tgz)
            gzip -d < "$tarball" | tar -C "$LFS" -xvf -
            ;;
        *.tar)
            tar -C "$LFS" -xvf "$tarball"
            ;;
        *)
            echo "install_binary_pkg: extensão de arquivo não suportada: $tarball" >&2
            rm -f "$pre_snap"
            return 1
            ;;
    esac

    snapshot_fs "$post_snap"

    # Gera manifest com tipos (F/L/D)
    generate_manifest_from_snapshots "$pre_snap" "$post_snap" "$manifest"

    rm -f "$pre_snap" "$post_snap"

    write_meta_binary "$pkg" "$version" "$tarball"

    echo "Pacote binário '$pkg' instalado com sucesso."
}

cmd_install() {
    if [[ $# -lt 1 ]]; then
        die "Uso: $CMD_NAME install <arquivo.tar.* | nome_pacote>"
    fi

    local arg="$1"
    local tarball=""

    if [[ -f "$arg" ]]; then
        tarball="$arg"
    else
        # Busca em ADM_BIN_PKG_DIR um arquivo que comece com arg-
        shopt -s nullglob
        local candidates=("$ADM_BIN_PKG_DIR/$arg"-*.tar.*)
        shopt -u nullglob
        if [[ ${#candidates[@]} -eq 0 ]]; then
            die "Nenhum pacote binário encontrado em $ADM_BIN_PKG_DIR para: $arg"
        elif [[ ${#candidates[@]} -gt 1 ]]; then
            echo "Múltiplos pacotes encontrados para '$arg' em $ADM_BIN_PKG_DIR:" >&2
            printf '  - %s\n' "${candidates[@]}" >&2
            die "Especifique o arquivo exato."
        fi
        tarball="${candidates[0]}"
    fi

    install_binary_pkg "$tarball"
}

#============================================================
# UPDATE – checagem de versões novas no upstream
#============================================================
# Para cada pacote:
#   - Versão atual vem de:
#        meta: VERSION="..."
#      (que por sua vez, vem de $pkg_dir/$pkg.version, se existir)
#
#   - Versão mais nova vem de:
#        $pkg_dir/$pkg.upstream  (opcional, executável)
#        -> deve imprimir a versão mais recente em uma linha
#
#   - Resultado é salvo em:
#        $ADM_STATE_DIR/updates-YYYYmmdd-HHMMSS.txt
#============================================================

check_upstream_for_pkg() {
    local pkg="$1"
    local candidates=()
    local dir helper

    # Procura helpers *.upstream em diretórios de pacote
    for dir in "$LFS_BUILD_SCRIPTS_DIR"/*/"$pkg"; do
        [[ -d "$dir" ]] || continue
        helper="$dir/$pkg.upstream"
        if [[ -x "$helper" ]]; then
            candidates+=("$helper")
        fi
    done

    if (( ${#candidates[@]} == 0 )); then
        # 2 = sem helper upstream
        return 2
    fi

    if (( ${#candidates[@]} > 1 )); then
        echo "Pacote '$pkg' possui múltiplos helpers upstream, ignorando:" >&2
        local h
        for h in "${candidates[@]}"; do
            echo "  $h" >&2
        done
        # 2 = ambíguo / sem upstream utilizável
        return 2
    fi

    helper="${candidates[0]}"

    # Executa helper: deve imprimir "versão [info extra...]"
    local out first rc
    if ! out="$("$helper")"; then
        # 1 = erro na execução do helper
        echo "Erro ao executar helper upstream para '$pkg': $helper" >&2
        return 1
    fi

    # Pega primeira linha e primeiro campo
    out="${out%%$'\n'*}"
    # remove espaços à esquerda
    out="${out#"${out%%[![:space:]]*}"}"
    # remove espaços à direita
    out="${out%"${out##*[![:space:]]}"}"

    first="${out%%[[:space:]]*}"

    if [[ -z "$first" ]]; then
        echo "Helper upstream para '$pkg' não retornou versão válida." >&2
        return 1
    fi

    printf '%s\n' "$first"
    return 0
}

version_is_newer() {
    local current="$1"
    local latest="$2"

    # Se qualquer um estiver vazio, não consideramos "mais novo"
    if [[ -z "$current" || -z "$latest" ]]; then
        return 1
    fi

    local top
    top="$(printf '%s\n%s\n' "$current" "$latest" | LC_ALL=C sort -V | tail -n1)"

    [[ "$top" != "$current" ]]
}

cmd_update() {
    adm_ensure_db
    mkdir -p "$ADM_STATE_DIR"

    local pkgs=()
    if (( $# > 0 )); then
        pkgs=("$@")
    else
        local meta
        for meta in "$ADM_PKG_META_DIR"/*.meta; do
            [[ -f "$meta" ]] || continue
            pkgs+=("$(basename "${meta%.meta}")")
        done
    fi

    if (( ${#pkgs[@]} == 0 )); then
        echo "Nenhum pacote instalado encontrado para verificar atualizações."
        return 0
    fi

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local report="$ADM_STATE_DIR/updates-$ts.txt"

    local pkg current latest
    local n_updates=0 n_uptodate=0 n_unknown=0 n_nohelper=0

    {
        echo "Relatório de atualizações - $ts"
        echo "LFS: ${LFS:-/}"
        echo

        for pkg in "${pkgs[@]}"; do
            current="$(get_installed_version "$pkg" || true)"

            if [[ -z "$current" ]]; then
                echo "$pkg: versão instalada desconhecida."
                ((n_unknown++))
            fi

            if ! latest="$(check_upstream_for_pkg "$pkg")"; then
                case $? in
                    2)
                        echo "$pkg: sem helper upstream disponível."
                        ((n_nohelper++))
                        ;;
                    1|*)
                        echo "$pkg: erro ao consultar upstream (veja logs)."
                        ;;
                esac
                continue
            fi

            if [[ -z "$current" ]]; then
                echo "$pkg: instalado (versão desconhecida) -> upstream: $latest"
                ((n_updates++))
                continue
            fi

            if version_is_newer "$current" "$latest"; then
                echo "$pkg: $current -> $latest (ATUALIZAÇÃO DISPONÍVEL)"
                ((n_updates++))
            else
                echo "$pkg: $current (já está na versão mais recente: $latest)"
                ((n_uptodate++))
            fi
        done

        echo
        echo "Resumo:"
        echo "  Com atualização disponível: $n_updates"
        echo "  Já atualizados:            $n_uptodate"
        echo "  Versão desconhecida:       $n_unknown"
        echo "  Sem helper upstream:       $n_nohelper"
    } > "$report"

    echo "Relatório de atualizações gerado em: $report"
}

#============================================================
# Status / listagem
#============================================================

cmd_status() {
    local mode_desc="LFS em árvore separada"
    if [[ "${LFS:-}" == "/" ]]; then
        mode_desc="MODO HOST (sistema principal)"
    fi

    cat <<EOF
=== ADM / LFS Status ===
Modo..................: $mode_desc
LFS base..............: $LFS
Sources...............: $LFS_SOURCES_DIR
Tools.................: $LFS_TOOLS_DIR
Build scripts.........: $LFS_BUILD_SCRIPTS_DIR
Logs..................: $LFS_LOG_DIR
ADM DB................: $ADM_DB_DIR
Meta de pacotes.......: $ADM_PKG_META_DIR
Manifests.............: $ADM_MANIFEST_DIR
Log geral.............: $ADM_LOG_FILE
Pacotes binários......: $ADM_BIN_PKG_DIR
CHROOT_FOR_BUILDS.....: $CHROOT_FOR_BUILDS

EOF
}

cmd_list_installed() {
    adm_ensure_db
    echo "=== Pacotes instalados (registrados) ==="
    local meta pkg ver
    shopt -s nullglob
    for meta in "$ADM_PKG_META_DIR"/*.meta; do
        [[ -f "$meta" ]] || continue
        pkg="$(basename "${meta%.meta}")"
        ver="$(read_meta_field "$pkg" VERSION 2>/dev/null || true)"
        if [[ -n "$ver" ]]; then
            printf '  - %-20s  (%s)\n' "$pkg" "$ver"
        else
            printf '  - %-20s  (versão desconhecida)\n' "$pkg"
        fi
    done
    shopt -u nullglob
}

#============================================================
# Verificação de integridade de um pacote
#============================================================
verify_pkg() {
    local pkg="$1"

    adm_ensure_db

    local meta manifest
    meta="$(pkg_meta_file "$pkg")"
    manifest="$(pkg_manifest_file "$pkg")"

    echo "=== Verificando pacote: $pkg ==="

    local errors=0 warnings=0
    local missing=0 out_of_lfs=0 suspicious=0 total=0

    #------------------------------
    # Verifica meta
    #------------------------------
    if [[ ! -f "$meta" ]]; then
        echo "  [ERRO] Arquivo meta não encontrado: $meta"
        ((errors++))
    else
        local name status script version
        name="$(read_meta_field "$pkg" NAME 2>/dev/null || true)"
        status="$(read_meta_field "$pkg" STATUS 2>/dev/null || true)"
        script="$(read_meta_field "$pkg" SCRIPT 2>/dev/null || true)"
        version="$(read_meta_field "$pkg" VERSION 2>/dev/null || true)"

        if [[ -z "$name" ]]; then
            echo "  [AVISO] Campo NAME vazio em meta."
            ((warnings++))
        elif [[ "$name" != "$pkg" ]]; then
            echo "  [AVISO] NAME em meta ($name) difere do nome do pacote ($pkg)."
            ((warnings++))
        fi

        if [[ -z "$status" ]]; then
            echo "  [AVISO] Campo STATUS vazio em meta."
            ((warnings++))
        elif [[ "$status" != "installed" ]]; then
            echo "  [AVISO] STATUS em meta é '$status' (esperado: 'installed')."
            ((warnings++))
        fi

        if [[ -n "$script" && "$script" != binary:* && ! -f "$script" ]]; then
            echo "  [AVISO] SCRIPT em meta aponta para arquivo inexistente: $script"
            ((warnings++))
        fi

        echo "  Meta: OK (com $warnings aviso(s))."
    fi

    #------------------------------
    # Verifica manifest
    #------------------------------
    if [[ ! -f "$manifest" ]]; then
        echo "  [ERRO] Manifesto não encontrado: $manifest"
        ((errors++))
    else
        local line path

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue

            path="$line"
            # tira espaços em volta
            path="${path#"${path%%[![:space:]]*}"}"
            path="${path%"${path##*[![:space:]]}"}"

            [[ -z "$path" ]] && continue
            ((total++))

            # Caminho deve estar dentro de $LFS
            case "$path" in
                "$LFS"|"$LFS"/*)
                    ;;
                *)
                    echo "  [AVISO] Caminho fora de \$LFS no manifest: $path"
                    ((warnings++))
                    ((out_of_lfs++))
                    continue
                    ;;
            esac

            # Não permite '..' nos segmentos: caminho suspeito
            if [[ "$path" == *"/../"* || "$path" == "../"* || "$path" == *"/.." ]]; then
                echo "  [AVISO] Caminho suspeito (contém '..') no manifest: $path"
                ((warnings++))
                ((suspicious++))
                continue
            fi

            if [[ -e "$path" || -L "$path" ]]; then
                # Existe (arquivo, dir ou link): consideramos OK
                :
            else
                echo "  [ERRO] Caminho do manifest não existe mais: $path"
                ((errors++))
                ((missing++))
            fi
        done < "$manifest"

        echo "  Manifesto: $total entradas; ausentes=$missing; fora_LFS=$out_of_lfs; suspeitos=$suspicious"
    fi

    if (( errors == 0 && missing == 0 && out_of_lfs == 0 && suspicious == 0 )); then
        echo "  => OK: nenhum problema encontrado."
        echo
        return 0
    else
        echo "  => PROBLEMAS detectados: erros=$errors, avisos=$warnings"
        echo
        return 1
    fi
}

#============================================================
# Comando: verify
#============================================================
cmd_verify() {
    adm_ensure_db

    local pkgs=()

    if [[ $# -gt 0 ]]; then
        pkgs=("$@")
    else
        shopt -s nullglob
        local meta
        for meta in "$ADM_PKG_META_DIR"/*.meta; do
            [[ -f "$meta" ]] || continue
            pkgs+=("$(basename "${meta%.meta}")")
        done
        shopt -u nullglob
    fi

    if (( ${#pkgs[@]} == 0 )); then
        echo "Nenhum pacote instalado encontrado para verificar."
        return 0
    fi

    local ok=0 bad=0 pkg

    for pkg in "${pkgs[@]}"; do
        if verify_pkg "$pkg"; then
            ((ok++))
        else
            ((bad++))
        fi
    done

    echo "=== Resumo da verificação ==="
    echo "  Pacotes OK.............: $ok"
    echo "  Pacotes com problemas..: $bad"

    # Se ADM_VERIFY_STRICT=1 e houver problemas, retorna erro
    if (( bad > 0 )) && [[ "${ADM_VERIFY_STRICT:-0}" -eq 1 ]]; then
        return 1
    fi

    return 0
}

#============================================================
# main
#============================================================

main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    load_config

    local cmd="$1"; shift || true

        case "$cmd" in
        status)
            cmd_status
            ;;
        run-build)
            cmd_run_build "$@"
            ;;
        list-installed)
            cmd_list_installed
            ;;
        uninstall)
            cmd_uninstall "$@"
            ;;
        verify)
            cmd_verify "$@"
            ;;
        install)
            cmd_install "$@"
            ;;
        update)
            cmd_update "$@"
            ;;
        mount)
            require_root
            mount_virtual_fs
            ;;
        umount|unmount)
            require_root
            umount_virtual_fs
            ;;
        chroot)
            cmd_chroot
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "Comando desconhecido: $cmd" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
