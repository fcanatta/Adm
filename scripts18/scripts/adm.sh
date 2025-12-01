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

# Executa um arquivo que está em $LFS/algum/caminho dentro do chroot
chroot_exec_file() {
    local abs="$1"
    local rel="${abs#$LFS}"
    if [[ "$rel" == "$abs" ]]; then
        die "Arquivo $abs não está dentro de LFS ($LFS)"
    fi
    rel="${rel#/}"
    chroot "$LFS" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PATH=/usr/bin:/usr/sbin:/bin:/sbin \
        LFS="/" \
        /bin/bash -lc "/$rel"
}

#============================================================
# Snapshot / Manifest
#============================================================

snapshot_fs() {
    local outfile="$1"

    if [[ ! -d "$LFS" ]]; then
        die "Diretório base LFS não existe: $LFS"
    fi

    find "$LFS" -xdev \
        \( -path "$ADM_DB_DIR" \
           -o -path "$LFS_BUILD_SCRIPTS_DIR" \
           -o -path "$LFS_SOURCES_DIR" \
           -o -path "$LFS_LOG_DIR" \) -prune -o \
        \( -type f -o -type l -o -type d \) -print \
        | sort > "$outfile"
}

pkg_manifest_file() {
    local pkg="$1"
    echo "$ADM_MANIFEST_DIR/$pkg.manifest"
}

pkg_meta_file() {
    local pkg="$1"
    echo "$ADM_PKG_META_DIR/$pkg.meta"
}

is_installed() {
    local pkg="$1"
    local manifest
    manifest="$(pkg_manifest_file "$pkg")"
    [[ -f "$manifest" ]]
}

#============================================================
# Localização de scripts / hooks / deps
#============================================================

find_build_script() {
    local pkg="$1"
    local matches=()

    shopt -s nullglob
    matches=( "$LFS_BUILD_SCRIPTS_DIR"/*/"$pkg"/"$pkg".sh )
    shopt -u nullglob

    if (( ${#matches[@]} == 0 )); then
        die "Script de build não encontrado para pacote '$pkg' em $LFS_BUILD_SCRIPTS_DIR/*/$pkg/$pkg.sh"
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

run_hook_host() {
    local hook="$1"
    local phase="$2"
    local pkg="$3"

    if [[ -x "$hook" ]]; then
        echo ">> [$pkg] Executando hook $phase: $(basename "$hook")"
        adm_log "HOOK $phase $pkg $hook"
        "$hook"
    fi
}

run_hook_chroot() {
    local hook="$1"
    local phase="$2"
    local pkg="$3"

    if [[ -x "$hook" ]]; then
        echo ">> [$pkg] Executando hook (chroot) $phase: $(basename "$hook")"
        adm_log "HOOK_CHROOT $phase $pkg $hook"
        chroot_exec_file "$hook"
    fi
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
    local meta
    meta="$(pkg_meta_file "$pkg")"
    [[ -f "$meta" ]] || return 1

    # shellcheck disable=SC1090
    . "$meta"
    # usa eval pra pegar o valor da variável de forma genérica
    eval "printf '%s\n' \"\${$key:-}\""
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

    local script pkg_dir
    script="$(find_build_script "$pkg")"
    pkg_dir="$(pkg_dir_from_script "$script")"

    echo ">> [$pkg] Iniciando build"
    adm_log "BUILD START $pkg SCRIPT=$script"

    local ts logfile
    ts="$(date +'%Y%m%d-%H%M%S')"
    logfile="$LFS_LOG_DIR/${pkg}-$ts.log"

    mkdir -p "$ADM_STATE_DIR"
    local pre_snap post_snap
    pre_snap="$(mktemp "$ADM_STATE_DIR/${pkg}.pre.XXXXXX")"
    post_snap="$(mktemp "$ADM_STATE_DIR/${pkg}.post.XXXXXX")"

    snapshot_fs "$pre_snap"

    local pre_install_hook post_install_hook
    pre_install_hook="$(hook_path "$pkg_dir" "$pkg" "pre_install")"
    post_install_hook="$(hook_path "$pkg_dir" "$pkg" "post_install")"

    # Decide se vai usar chroot
    local use_chroot=0
    if is_cross_script "$script"; then
        use_chroot=0
    else
        if [[ "$LFS" != "/" && "$CHROOT_FOR_BUILDS" -eq 1 ]]; then
            use_chroot=1
        fi
    fi

    # Se for usar chroot, exija root ANTES de tentar montar/chrootar
    if [[ "$use_chroot" -eq 1 ]]; then
        require_root
    fi

    local rc=0
    local mounted=0

    {
        echo "==> Build do pacote: $pkg"
        echo "    LFS=$LFS"
        echo "    Script: $script"
        echo "    Data: $(date)"
        echo "    CHROOT_FOR_BUILDS=$CHROOT_FOR_BUILDS (use_chroot=$use_chroot)"

        if [[ "$use_chroot" -eq 1 ]]; then
            echo ">> [$pkg] Build será feito em chroot."
            mount_virtual_fs
            mounted=1

            run_hook_chroot "$pre_install_hook" "pre_install" "$pkg"
            echo ">> [$pkg] Executando script de build (chroot)..."
            chroot_exec_file "$script"
            run_hook_chroot "$post_install_hook" "post_install" "$pkg"
        else
            run_hook_host "$pre_install_hook" "pre_install" "$pkg"
            echo ">> [$pkg] Executando script de build (host)..."
            "$script"
            run_hook_host "$post_install_hook" "post_install" "$pkg"
        fi

        echo ">> [$pkg] Build concluído."
    } >"$logfile" 2>&1 || rc=$?

    if [[ "$mounted" -eq 1 ]]; then
        umount_virtual_fs || true
    fi

    if [[ "$rc" -ne 0 ]]; then
        adm_log "BUILD FAIL $pkg RC=$rc LOG=$logfile"
        echo ">> [$pkg] ERRO no build. Veja o log: $logfile" >&2
        exit "$rc"
    fi

    snapshot_fs "$post_snap"

    local manifest
    manifest="$(pkg_manifest_file "$pkg")"
    comm -13 "$pre_snap" "$post_snap" >"$manifest"

    rm -f "$pre_snap" "$post_snap"

    local deps
    deps="$(read_deps "$pkg" || true)"

    write_meta "$pkg" "$script" "$deps"

    adm_log "BUILD OK $pkg MANIFEST=$manifest LOG=$logfile"
    echo ">> [$pkg] Build concluído com sucesso. Manifesto: $manifest"
    echo ">> [$pkg] Log de build: $logfile"
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

    local pkg
    for pkg in "$@"; do
        build_with_deps "$pkg"
    done
}

#============================================================
# Uninstall
#============================================================

uninstall_pkg() {
    local pkg="${1:-}"
    [[ -z "$pkg" ]] && die "Uso: $CMD_NAME uninstall <pacote>"

    adm_ensure_db

    local manifest meta
    manifest="$(pkg_manifest_file "$pkg")"
    meta="$(pkg_meta_file "$pkg")"

    [[ -f "$manifest" ]] || die "Manifesto não encontrado para $pkg: $manifest"
    [[ -f "$meta" ]] || die "Meta não encontrado para $pkg: $meta"

    if ! command -v tac >/dev/null 2>&1; then
        die "'tac' não encontrado no PATH (necessário para uninstall)."
    fi

    require_root

    adm_log "UNINSTALL START $pkg"
    echo ">> [UNINSTALL] Removendo pacote $pkg"

    local script pkg_dir pre_un post_un
    script="$(read_meta_field "$pkg" SCRIPT 2>/dev/null || true)"
    pkg_dir=""

    # Se for pacote de fonte (script real existe), usamos hooks
    if [[ -n "$script" && -f "$script" ]]; then
        pkg_dir="$(pkg_dir_from_script "$script")"
        pre_un="$(hook_path "$pkg_dir" "$pkg" "pre_uninstall")"
        post_un="$(hook_path "$pkg_dir" "$pkg" "post_uninstall")"
        run_hook_host "$pre_un" "pre_uninstall" "$pkg"
    else
        pre_un=""
        post_un=""
    fi

    local path
    tac "$manifest" | while read -r path; do
        [[ -z "$path" ]] && continue

        case "$path" in
            "$LFS"|"$LFS"/*)
                ;;
            *)
                echo "  ! Caminho fora de LFS ignorado: $path" >&2
                continue
                ;;
        esac

        if [[ -f "$path" || -L "$path" ]]; then
            rm -f "$path" || echo "  ! Falha ao remover arquivo $path" >&2
        elif [[ -d "$path" ]]; then
            rmdir "$path" 2>/dev/null || true
        fi
    done

    rm -f "$manifest" "$meta"

    if [[ -n "${post_un:-}" ]]; then
        run_hook_host "$post_un" "post_uninstall" "$pkg"
    fi

    adm_log "UNINSTALL OK $pkg"
    echo ">> [UNINSTALL] Pacote $pkg removido."
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

    # Tentativa de formato: nome-versao-arquitetura
    if [[ "$base" == *-* ]]; then
        arch="${base##*-}"
        name_ver="${base%-*}"
    else
        name_ver="$base"
        arch=""
    fi

    if [[ "$name_ver" == *-* ]]; then
        pkg="${name_ver%%-*}"
        version="${name_ver#*-}"
    else
        pkg="$name_ver"
        version=""
    fi

    printf '%s\n' "$pkg" "$version"
}

install_binary_pkg() {
    local tarball="$1"

    adm_ensure_db
    require_root

    local pkg version
    read -r pkg version < <(parse_pkg_from_tarball "$tarball")

    [[ -n "$pkg" ]] || die "Não foi possível determinar o nome do pacote a partir de: $tarball"

    echo ">> [INSTALL] Instalando pacote binário $tarball"
    echo ">> [INSTALL] Pacote: $pkg Versão: ${version:-desconhecida}"

    adm_log "INSTALL START $pkg TARBALL=$tarball VERSION=$version"

    mkdir -p "$ADM_STATE_DIR"
    local pre_snap post_snap
    pre_snap="$(mktemp "$ADM_STATE_DIR/${pkg}.prebin.XXXXXX")"
    post_snap="$(mktemp "$ADM_STATE_DIR/${pkg}.postbin.XXXXXX")"

    snapshot_fs "$pre_snap"

    extract_tarball_into_lfs "$tarball"

    snapshot_fs "$post_snap"

    local manifest
    manifest="$(pkg_manifest_file "$pkg")"
    comm -13 "$pre_snap" "$post_snap" >"$manifest"

    rm -f "$pre_snap" "$post_snap"

    write_meta_binary "$pkg" "$version" "$tarball"

    adm_log "INSTALL OK $pkg TARBALL=$tarball MANIFEST=$manifest"
    echo ">> [INSTALL] Pacote $pkg instalado a partir de binário."
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
    local pkg_dir upstream latest
    local candidates=()

    # Procurar diretórios de pacote que tenham um helper .upstream executável
    shopt -s nullglob
    for pkg_dir in "$LFS_BUILD_SCRIPTS_DIR"/*/"$pkg"; do
        if [[ -x "$pkg_dir/$pkg.upstream" ]]; then
            candidates+=("$pkg_dir/$pkg.upstream")
        fi
    done
    shopt -u nullglob

    # Nenhum helper encontrado => "sem upstream", mas NÃO morre, só retorna 2
    if [[ ${#candidates[@]} -eq 0 ]]; then
        return 2
    fi

    # Se houver mais de um helper, consideramos ambíguo e também retornamos 2,
    # para não derrubar o update inteiro.
    if [[ ${#candidates[@]} -gt 1 ]]; then
        return 2
    fi

    upstream="${candidates[0]}"

    if ! latest="$("$upstream")"; then
        # helper existe mas falhou
        return 1
    fi

    # Pega só a primeira palavra/linha
    latest="${latest%%[[:space:]]*}"

    [[ -n "$latest" ]] || return 1

    printf '%s\n' "$latest"
}

version_is_newer() {
    local current="$1"
    local latest="$2"

    if [[ -z "$current" || -z "$latest" ]]; then
        return 1
    fi

    local top
    top="$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n1)"

    [[ "$top" != "$current" ]]
}

cmd_update() {
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

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        echo ">> [UPDATE] Nenhum pacote registrado."
        return 0
    fi

    mkdir -p "$ADM_STATE_DIR"
    local ts report
    ts="$(date +'%Y%m%d-%H%M%S')"
    report="$ADM_STATE_DIR/updates-$ts.txt"

    echo "# Relatório de atualizações - $ts" >"$report"
    echo "# Formato: pacote versão_instalada -> versão_upstream" >>"$report"
    echo >>"$report"

    local pkg current latest rc any=0

    for pkg in "${pkgs[@]}"; do
        current="$(get_installed_version "$pkg" || true)"

        if [[ -z "$current" ]]; then
            echo ">> [UPDATE] $pkg: versão instalada desconhecida (VERSION vazio em meta)." >&2
            echo "$pkg: INSTALADO (versão desconhecida; crie $pkg.version no script)" >>"$report"
            continue
        fi

        if ! latest="$(check_upstream_for_pkg "$pkg")"; then
            rc=$?
            case "$rc" in
                1)
                    echo ">> [UPDATE] $pkg: erro ao consultar upstream (script .upstream falhou)." >&2
                    echo "$pkg: ERRO ao consultar upstream" >>"$report"
                    ;;
                2)
                    echo ">> [UPDATE] $pkg: nenhum helper upstream (.upstream) definido; ignorando." >&2
                    echo "$pkg: sem helper upstream (.upstream ausente)" >>"$report"
                    ;;
                *)
                    echo ">> [UPDATE] $pkg: erro desconhecido no helper upstream (rc=$rc)." >&2
                    echo "$pkg: ERRO desconhecido no upstream (rc=$rc)" >>"$report"
                    ;;
            esac
            continue
        fi

        if version_is_newer "$current" "$latest"; then
            any=1
            echo ">> [UPDATE] $pkg: nova versão encontrada: $current -> $latest"
            echo "$pkg: $current -> $latest" >>"$report"
        else
            echo ">> [UPDATE] $pkg: já está na versão mais recente ($current)."
        fi
    done

    echo
    echo ">> [UPDATE] Relatório salvo em: $report"
    if [[ "$any" -eq 0 ]]; then
        echo ">> [UPDATE] Nenhum pacote com versão mais nova encontrada (entre os que têm helper upstream)."
    fi
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
