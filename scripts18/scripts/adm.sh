#!/usr/bin/env bash
#============================================================
#  ADM - Gerenciador de builds para LFS / sistema final
#
#  - Usa scripts de construção em:
#      $LFS/packages/<categoria>/<programa>/<programa>.sh
#      $LFS/packages/<categoria>/<programa>/<programa>.deps
#      $LFS/packages/<categoria>/<programa>/<programa>.pre_install
#      $LFS/packages/<categoria>/<programa>/<programa>.post_install
#      $LFS/packages/<categoria>/<programa>/<programa>.pre_uninstall
#      $LFS/packages/<categoria>/<programa>/<programa>.post_uninstall
#
#  - Resolve dependências (.deps)
#  - Gera meta + manifest em $LFS/var/adm
#  - Uninstall por manifest + hooks
#  - Retoma builds (pula pacotes já instalados)
#  - chroot automático (monta /dev,/proc,/sys,/run, entra e sai)
#  - Suporta cross-toolchain em $LFS/tools (scripts como binutils-pass1.sh)
#============================================================

set -euo pipefail

CMD_NAME="${0##*/}"
LFS_CONFIG="${LFS_CONFIG:-/etc/adm.conf}"

# Variáveis globais preenchidas após load_config
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

# Pilha de dependências para detectar ciclos
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
  run-build <pkg>...          Constrói um ou mais pacotes (com deps)
  list-installed              Lista pacotes registrados como instalados
  uninstall <pkg>             Desinstala um pacote via manifest + hooks

Chroot / LFS:
  mount                       Monta /dev,/proc,/sys,/run em \$LFS
  umount                      Desmonta /dev,/proc,/sys,/run de \$LFS
  chroot                      Monta, entra em chroot, desmonta ao sair

Observações:
  - O valor de LFS vem do ambiente ou de $LFS_CONFIG.
    Exemplos:
        export LFS=/mnt/lfs   # fase de construção
        export LFS=/          # depois que o LFS vira sistema principal

  - Scripts de construção devem estar em:
      \$LFS/packages/<categoria>/<programa>/<programa>.sh

  - Dependências: arquivo .deps no mesmo diretório, com 1 pacote por linha.
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

    # LFS precisa estar definido no final
    : "${LFS:?LFS não definido. Exporte LFS=/mnt/lfs ou LFS=/ e/ou ajuste $LFS_CONFIG}"

    # Diretórios derivados (com defaults sensatos)
    LFS_SOURCES_DIR="${LFS_SOURCES_DIR:-$LFS/sources}"
    LFS_TOOLS_DIR="${LFS_TOOLS_DIR:-$LFS/tools}"
    LFS_BUILD_SCRIPTS_DIR="${LFS_BUILD_SCRIPTS_DIR:-$LFS/packages}"
    LFS_LOG_DIR="${LFS_LOG_DIR:-$LFS/logs}"

    ADM_DB_DIR="${ADM_DB_DIR:-$LFS/var/adm}"
    ADM_PKG_META_DIR="$ADM_DB_DIR/pkgs"
    ADM_MANIFEST_DIR="$ADM_DB_DIR/manifests"
    ADM_STATE_DIR="$ADM_DB_DIR/state"
    ADM_LOG_FILE="$ADM_DB_DIR/adm.log"
}

adm_ensure_db() {
    mkdir -p "$ADM_PKG_META_DIR" "$ADM_MANIFEST_DIR" "$ADM_STATE_DIR" "$LFS_LOG_DIR"
}

#============================================================
# Montagem e chroot
#============================================================

mount_virtual_fs() {
    echo ">> Montando sistemas de arquivos virtuais em $LFS ..."

    if [[ -z "${LFS:-}" ]]; then
        die "LFS não definido (mount_virtual_fs)."
    fi

    mkdir -p "$LFS/dev" "$LFS/dev/pts" "$LFS/proc" "$LFS/sys" "$LFS/run"

    # /dev
    if ! mountpoint -q "$LFS/dev"; then
        mount --bind /dev "$LFS/dev"
        echo "  - /dev montado."
    fi

    # /dev/pts
    if ! mountpoint -q "$LFS/dev/pts"; then
        mount -t devpts devpts "$LFS/dev/pts" -o gid=5,mode=620
        echo "  - /dev/pts montado."
    fi

    # /proc
    if ! mountpoint -q "$LFS/proc"; then
        mount -t proc proc "$LFS/proc"
        echo "  - /proc montado."
    fi

    # /sys
    if ! mountpoint -q "$LFS/sys"; then
        mount -t sysfs sysfs "$LFS/sys"
        echo "  - /sys montado."
    fi

    # /run
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

    if [[ -z "${LFS:-}" ]]; then
        die "LFS não definido (snapshot_fs)."
    fi
    if [[ ! -d "$LFS" ]]; then
        die "Diretório base LFS não existe: $LFS"
    fi

    # Apenas arquivos e symlinks, dentro de LFS, ignorando:
    #  - banco de dados do ADM
    #  - diretório de scripts de build
    #  - diretório de sources
    find "$LFS" -xdev \
        \( -path "$ADM_DB_DIR" -o -path "$LFS_BUILD_SCRIPTS_DIR" -o -path "$LFS_SOURCES_DIR" \) -prune -o \
        \( -type f -o -type l \) -print \
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

write_meta() {
    local pkg="$1"
    local script="$2"
    local deps="$3"

    local meta
    meta="$(pkg_meta_file "$pkg")"

    cat >"$meta" <<EOF
NAME="$pkg"
SCRIPT="$script"
BUILT_AT="$(date +'%F %T')"
DEPS="$deps"
STATUS="installed"
EOF
}

#============================================================
# Localização de scripts / hooks / deps
#============================================================

find_build_script() {
    local pkg="$1"
    local pattern="$LFS_BUILD_SCRIPTS_DIR"/*/"$pkg"/"$pkg".sh

    shopt -s nullglob
    local matches=($pattern)
    shopt -u nullglob

    if [[ ${#matches[@]} -eq 0 ]]; then
        die "Script de build não encontrado para pacote '$pkg' em $LFS_BUILD_SCRIPTS_DIR/*/$pkg/$pkg.sh"
    elif [[ ${#matches[@]} -gt 1 ]]; then
        echo "Foram encontrados múltiplos scripts para '$pkg':" >&2
        printf '  - %s\n' "${matches[@]}" >&2
        die "Ambiguidade: mais de um script de build para '$pkg'."
    fi

    echo "${matches[0]}"
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

run_hook() {
    local hook="$1"
    local phase="$2"
    local pkg="$3"

    if [[ -x "$hook" ]]; then
        echo ">> [$pkg] Executando hook $phase: $(basename "$hook")"
        adm_log "HOOK $phase $pkg $hook"
        "$hook"
    fi
}

read_deps() {
    local pkg="$1"
    local script
    script="$(find_build_script "$pkg")"
    local dir
    dir="$(pkg_dir_from_script "$script")"
    local deps_file="$dir/$pkg.deps"

    if [[ ! -f "$deps_file" ]]; then
        echo ""
        return 0
    fi

    # Lê dependências, ignorando linhas em branco e comentários
    local deps=()
    local line
    while IFS= read -r line; do
        # remove espaços nas pontas
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        deps+=("$line")
    done <"$deps_file"

    printf '%s\n' "${deps[@]}"
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

    # logs
    local ts logfile
    ts="$(date +'%Y%m%d-%H%M%S')"
    logfile="$LFS_LOG_DIR/${pkg}-$ts.log"

    # snapshots
    mkdir -p "$ADM_STATE_DIR"
    local pre_snap post_snap
    pre_snap="$(mktemp "$ADM_STATE_DIR/${pkg}.pre.XXXXXX")"
    post_snap="$(mktemp "$ADM_STATE_DIR/${pkg}.post.XXXXXX")"

    snapshot_fs "$pre_snap"

    # hooks de pre_install
    local pre_install_hook post_install_hook
    pre_install_hook="$(hook_path "$pkg_dir" "$pkg" "pre_install")"
    post_install_hook="$(hook_path "$pkg_dir" "$pkg" "post_install")"

    # Executa tudo com stdout/stderr indo para tee
    {
        echo "==== ADM build: $pkg ===="
        echo "Data: $(date +'%F %T')"
        echo "LFS : $LFS"
        echo "Script: $script"
        echo

        run_hook "$pre_install_hook" "pre_install" "$pkg"

        echo ">> [$pkg] Executando script de build..."
        adm_log "BUILD RUN $pkg"
        "$script"

        run_hook "$post_install_hook" "post_install" "$pkg"

        echo ">> [$pkg] Build concluído."
    } 2>&1 | tee "$logfile"

    snapshot_fs "$post_snap"

    # Calcula manifest (arquivos novos)
    local manifest
    manifest="$(pkg_manifest_file "$pkg")"
    comm -13 "$pre_snap" "$post_snap" >"$manifest"

    # Remove snapshots temporários
    rm -f "$pre_snap" "$post_snap"

    # Meta
    local deps
    deps="$(read_deps "$pkg" || true)"
    write_meta "$pkg" "$script" "$deps"

    adm_log "BUILD OK $pkg LOG=$logfile"
    echo ">> [$pkg] Registrado com sucesso. Manifest: $manifest"
}

#============================================================
# Build com dependências e retomada
#============================================================

build_with_deps() {
    local pkg="$1"

    # Se já instalado, não reconstrói (retomada automática)
    if is_installed "$pkg"; then
        echo ">> [$pkg] Já instalado, pulando."
        adm_log "SKIP INSTALLED $pkg"
        return 0
    fi

    # Lê deps
    local deps dep
    deps=()
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        deps+=("$dep")
    done < <(read_deps "$pkg" || true)

    # Controle de ciclo
    if [[ " $ADM_DEP_STACK " == *" $pkg "* ]]; then
        die "Detectado ciclo de dependências envolvendo '$pkg' (stack: $ADM_DEP_STACK)"
    fi

    local old_stack="$ADM_DEP_STACK"
    ADM_DEP_STACK="$ADM_DEP_STACK $pkg"

    # Constrói dependências primeiro
    for dep in "${deps[@]}"; do
        echo ">> [$pkg] Dependência: $dep"
        build_with_deps "$dep"
    done

    # Constrói o pacote em si
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

    require_root

    adm_log "UNINSTALL START $pkg"
    echo ">> [UNINSTALL] Removendo pacote $pkg"

    # Localiza script e diretório para hooks
    local script pkg_dir
    script="$(find_build_script "$pkg")"
    pkg_dir="$(pkg_dir_from_script "$script")"

    local pre_un_hook post_un_hook
    pre_un_hook="$(hook_path "$pkg_dir" "$pkg" "pre_uninstall")"
    post_un_hook="$(hook_path "$pkg_dir" "$pkg" "post_uninstall")"

    # Hook de pre_uninstall
    run_hook "$pre_un_hook" "pre_uninstall" "$pkg"

    # Remove arquivos listados no manifest
    local path
    # Remove em ordem reversa, pra tentar remover arquivos antes dos dirs
    tac "$manifest" | while read -r path; do
        [[ -z "$path" ]] && continue

        # Segurança: só remover dentro de LFS
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

    # Hook de post_uninstall
    run_hook "$post_un_hook" "post_uninstall" "$pkg"

    adm_log "UNINSTALL OK $pkg"
    echo ">> [UNINSTALL] Pacote $pkg removido."
}

cmd_uninstall() {
    uninstall_pkg "${1:-}"
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

EOF
}

cmd_list_installed() {
    adm_ensure_db
    echo "=== Pacotes instalados (registrados) ==="
    local meta pkg
    shopt -s nullglob
    for meta in "$ADM_PKG_META_DIR"/*.meta; do
        [[ -f "$meta" ]] || continue
        pkg="$(basename "${meta%.meta}")"
        printf '  - %s\n' "$pkg"
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
            # run-build pode ser executado como usuário normal (ex: lfs)
            cmd_run_build "$@"
            ;;
        list-installed)
            cmd_list_installed
            ;;
        uninstall)
            cmd_uninstall "$@"
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
