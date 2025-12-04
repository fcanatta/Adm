#!/usr/bin/env bash
# adm - mini gerenciador de pacotes / build system

set -euo pipefail

### CONFIGURAÇÃO GERAL #########################################################

ADM_REPO_URL="${ADM_REPO_URL:-https://github.com/fcanatta/Adm.git}"
ADM_REPO_DIR="${ADM_REPO_DIR:-/usr/src/adm}"
PKG_BASE_DIR="${ADM_REPO_DIR}/packages"

CACHE_SRC="${CACHE_SRC:-/var/cache/adm/sources}"
CACHE_PKG="${CACHE_PKG:-/var/cache/adm/packages}"

DB_DIR="${DB_DIR:-/var/lib/adm/db}"
PROFILES_DIR="${PROFILES_DIR:-/etc/adm/profiles}"

LOG_DIR="${LOG_DIR:-/var/log/adm}"
LOG_FILE="${LOG_DIR}/adm.log"

mkdir -p "$CACHE_SRC" "$CACHE_PKG" "$DB_DIR" "$LOG_DIR"

### CORES E LOG ###############################################################

if [ -t 1 ]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    MAGENTA=$'\033[35m'
    CYAN=$'\033[36m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; BOLD=""; RESET=""
fi

timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

log_append_file() {
    local level="$1"; shift
    printf "[%s] %s: %s\n" "$(timestamp)" "$level" "$*" >> "$LOG_FILE"
}

log_info() {
    log_append_file "INFO" "$@"
    printf "%s[INFO]%s %s\n" "$BLUE" "$RESET" "$*"
}

log_warn() {
    log_append_file "WARN" "$@"
    printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*" >&2
}

log_error() {
    log_append_file "ERROR" "$@"
    printf "%s[ERRO]%s %s\n" "$RED" "$RESET" "$*" >&2
}

log_success() {
    log_append_file "OK" "$@"
    printf "%s[ OK ]%s %s\n" "$GREEN" "$RESET" "$*"
}

die() {
    log_error "$*"
    exit 1
}

### UTILITÁRIOS ###############################################################

usage() {
    cat <<EOF
${BOLD}Uso:${RESET} adm <comando> [args]

Comandos principais:
  ${BOLD}build${RESET}    <programa|categoria/programa>   - compila e gera tar.zst (glibc/musl detectado)
  ${BOLD}install${RESET}  <programa|categoria/programa>   - instala no rootfs correspondente
  ${BOLD}uninstall${RESET} <programa|categoria/programa>  - remove com checagem de dependências reversas
  ${BOLD}search${RESET}   <padrão>                       - procura pacotes, mostra [ ✔️ ] se instalado
  ${BOLD}info${RESET}     <programa|categoria/programa>  - mostra informações do pacote + [ ✔️ ] se instalado
  ${BOLD}list${RESET}                                    - lista pacotes instalados
  ${BOLD}update-repo${RESET}                             - sincroniza /usr/src/adm com o git

Variáveis úteis:
  ADM_LIBC=glibc|musl     (força libc em vez de autodetectar)

Diretórios:
  Repo de pacotes: ${PKG_BASE_DIR}
  Cache sources:   ${CACHE_SRC}
  Cache pkgs:      ${CACHE_PKG}
  Banco de dados:  ${DB_DIR}
  Logs:            ${LOG_FILE}
EOF
}

check_requirements() {
    local reqs=(git find tar md5sum)
    local missing=0
    for bin in "${reqs[@]}"; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            log_error "Dependência obrigatória não encontrada: $bin"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        die "Instale as dependências acima e tente novamente."
    fi
}

ensure_repo() {
    if [ ! -d "$ADM_REPO_DIR/.git" ]; then
        log_info "Clonando repositório em $ADM_REPO_DIR..."
        mkdir -p "$(dirname "$ADM_REPO_DIR")"
        git clone "$ADM_REPO_URL" "$ADM_REPO_DIR" || die "Falha ao clonar repositório."
    fi
}

detect_libc() {
    local arg_libc="${1:-}"
    if [ -n "$arg_libc" ]; then
        echo "$arg_libc"
        return 0
    fi
    if [ -n "${ADM_LIBC:-}" ]; then
        echo "$ADM_LIBC"
        return 0
    fi
    if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
        echo "musl"
    else
        echo "glibc"
    fi
}

rootfs_for_libc() {
    case "$1" in
        glibc) echo "/opt/systems/glibc-rootfs" ;;
        musl)  echo "/opt/systems/musl-rootfs" ;;
        *) die "libc desconhecida: $1" ;;
    esac
}

pkg_dir() {
    local cat="$1" pkg="$2"
    echo "${PKG_BASE_DIR}/${cat}/${pkg}"
}

meta_path() {
    local cat="$1" pkg="$2" libc="$3"
    echo "${DB_DIR}/${cat}__${pkg}__${libc}.meta"
}

files_path() {
    local cat="$1" pkg="$2" libc="$3"
    echo "${DB_DIR}/${cat}__${pkg}__${libc}.files"
}

buildinfo_path() {
    local cat="$1" pkg="$2" libc="$3"
    echo "${CACHE_PKG}/${cat}__${pkg}__${libc}.buildinfo"
}

load_profile() {
    local libc="$1"
    local profile="${PROFILES_DIR}/${libc}.profile"
    if [ -f "$profile" ]; then
        # shellcheck disable=SC1090
        . "$profile"
    else
        log_warn "Profile $profile não encontrado. Continuando sem profile específico."
    fi
}

read_deps_file() {
    local depfile="$1"
    [ -f "$depfile" ] || return 0
    grep -Ev '^\s*($|#)' "$depfile" || true
}

pkg_is_installed_any_libc() {
    local cat="$1" pkg="$2"
    local meta
    for meta in "${DB_DIR}/${cat}__${pkg}__"*.meta; do
        [ -f "$meta" ] && return 0
    done
    return 1
}

find_reverse_deps() {
    local target="$1" libc="$2"
    local meta
    for meta in "$DB_DIR"/*.meta; do
        [ -e "$meta" ] || continue
        unset PKG_ID PKG_DEPS PKG_LIBC
        # shellcheck disable=SC1090
        . "$meta"
        [ "${PKG_LIBC:-}" = "$libc" ] || continue
        for d in ${PKG_DEPS:-}; do
            if [ "$d" = "$target" ]; then
                echo "${PKG_ID:-unknown}"
            fi
        done
    done
}

run_hook_dir() {
    local phase="$1" dir="$2" rootfs="$3" cat="$4" pkg="$5" libc="$6" version="$7"
    [ -d "$dir" ] || return 0
    log_info "Executando hooks de ${phase} em $dir"
    local script
    for script in "$dir"/*; do
        [ -x "$script" ] || continue
        ROOTFS="$rootfs" \
        ADM_CATEGORY="$cat" \
        ADM_PKG_NAME="$pkg" \
        ADM_LIBC="$libc" \
        ADM_PKG_VERSION="$version" \
        sh "$script"
    done
}

resolve_build_deps() {
    local libc="$1" cat="$2" pkg="$3"
    local depfile
    depfile="$(pkg_dir "$cat" "$pkg")/${pkg}.deps"
    local dep
    while read -r dep; do
        [ -n "$dep" ] || continue
        local dcat="${dep%/*}"
        local dpkg="${dep#*/}"
        log_info "(build) Dependência: $dep"
        "$0" build "${dcat}/${dpkg}" "$libc"
        "$0" install "${dcat}/${dpkg}" "$libc"
    done < <(read_deps_file "$depfile")
}

resolve_install_deps() {
    local libc="$1" cat="$2" pkg="$3"
    local depfile
    depfile="$(pkg_dir "$cat" "$pkg")/${pkg}.deps"
    local dep
    while read -r dep; do
        [ -n "$dep" ] || continue
        local dcat="${dep%/*}"
        local dpkg="${dep#*/}"
        log_info "(install) Dependência: $dep"
        "$0" install "${dcat}/${dpkg}" "$libc"
    done < <(read_deps_file "$depfile")
}

### RESOLUÇÃO DE PACOTE (NOME -> CATEGORIA/PROGRAMA) ###########################

# Retorna EXACTAMENTE uma linha: "categoria|programa|diretorio"
resolve_pkg_single() {
    local name="$1"

    [ -d "$PKG_BASE_DIR" ] || die "Diretório de pacotes não encontrado: $PKG_BASE_DIR"

    # Se vier como categoria/programa
    if [[ "$name" == */* ]]; then
        local cat="${name%/*}"
        local pkg="${name##*/}"
        local dir="${PKG_BASE_DIR}/${cat}/${pkg}"
        [ -d "$dir" ] || die "Pacote '$name' não encontrado em $PKG_BASE_DIR"
        echo "${cat}|${pkg}|${dir}"
        return 0
    fi

    # Caso contrário, procurar por nome em todas categorias
    local matches=()
    while IFS= read -r -d '' dir; do
        local pkg
        pkg="$(basename "$dir")"
        local cat
        cat="$(basename "$(dirname "$dir")")"
        [ "$pkg" = "$name" ] || continue
        if [ -x "${dir}/${pkg}.sh" ]; then
            matches+=("${cat}|${pkg}|${dir}")
        fi
    done < <(find "$PKG_BASE_DIR" -mindepth 2 -maxdepth 2 -type d -print0)

    local count="${#matches[@]}"

    if [ "$count" -eq 0 ]; then
        die "Pacote '$name' não encontrado em $PKG_BASE_DIR"
    elif [ "$count" -gt 1 ]; then
        log_error "Mais de um pacote com nome '$name' encontrado:"
        local m
        for m in "${matches[@]}"; do
            IFS='|' read -r cat pkg dir <<< "$m"
            printf "  - %s/%s (%s)\n" "$cat" "$pkg" "$dir" >&2
        done
        die "Use 'categoria/nome' para desambiguar (ex: utils/${name})."
    fi

    echo "${matches[0]}"
}

### COMANDOS ###################################################################

cmd_update_repo() {
    ensure_repo
    log_info "Atualizando repositório em $ADM_REPO_DIR..."
    (cd "$ADM_REPO_DIR" && git pull --ff-only) || die "Falha ao atualizar repositório."
    log_success "Repositório atualizado."
}

cmd_build() {
    local name="$1"
    local libc
    libc="$(detect_libc "${2:-}")"
    local rootfs
    rootfs="$(rootfs_for_libc "$libc")"

    ensure_repo

    local resolved cat pkg pdir
    resolved="$(resolve_pkg_single "$name")"
    IFS='|' read -r cat pkg pdir <<< "$resolved"

    local build_script="${pdir}/${pkg}.sh"
    [ -x "$build_script" ] || die "Script de build não encontrado ou não executável: $build_script"

    log_info "Build de ${cat}/${pkg} para libc=${libc}"
    load_profile "$libc"

    resolve_build_deps "$libc" "$cat" "$pkg"

    export ADM_CATEGORY="$cat"
    export ADM_PKG_NAME="$pkg"
    export ADM_LIBC="$libc"
    export ADM_ROOTFS="$rootfs"
    export ADM_CACHE_SRC="$CACHE_SRC"
    export ADM_CACHE_PKG="$CACHE_PKG"
    export ADM_BUILDINFO
    ADM_BUILDINFO="$(buildinfo_path "$cat" "$pkg" "$libc")"

    mkdir -p "$CACHE_SRC" "$CACHE_PKG"

    bash "$build_script" build "$libc"
    log_success "Build concluído para ${cat}/${pkg} (${libc})"
}

cmd_install() {
    local name="$1"
    local libc
    libc="$(detect_libc "${2:-}")"
    local rootfs
    rootfs="$(rootfs_for_libc "$libc")"

    ensure_repo

    mkdir -p "$rootfs"

    local resolved cat pkg pdir
    resolved="$(resolve_pkg_single "$name")"
    IFS='|' read -r cat pkg pdir <<< "$resolved"

    local buildinfo
    buildinfo="$(buildinfo_path "$cat" "$pkg" "$libc")"

    if [ ! -f "$buildinfo" ]; then
        log_warn "Nenhum buildinfo encontrado para ${cat}/${pkg} (${libc}). Chamando build..."
        cmd_build "${cat}/${pkg}" "$libc"
    fi

    # shellcheck disable=SC1090
    . "$buildinfo"

    [ -n "${PKG_TARBALL:-}" ] || die "PKG_TARBALL não definido em $buildinfo"
    [ -f "$PKG_TARBALL" ] || die "Tarball não encontrado: $PKG_TARBALL"

    resolve_install_deps "$libc" "$cat" "$pkg"

    local pre_dir="${pdir}/${pkg}.pre_install"
    local post_dir="${pdir}/${pkg}.post_install"

    run_hook_dir "pre_install" "$pre_dir" "$rootfs" "$cat" "$pkg" "$libc" "$PKG_VERSION"

    log_info "Instalando ${PKG_TARBALL} em ${rootfs}"
    local filelist
    filelist="$(mktemp)"
    tar -tf "$PKG_TARBALL" > "$filelist"
    tar -C "$rootfs" -xf "$PKG_TARBALL"

    local meta filesdb
    meta="$(meta_path "$cat" "$pkg" "$libc")"
    filesdb="$(files_path "$cat" "$pkg" "$libc")"

    mv "$filelist" "$filesdb"

    {
        echo "PKG_ID=\"${cat}/${pkg}\""
        echo "PKG_NAME=\"$pkg\""
        echo "PKG_CATEGORY=\"$cat\""
        echo "PKG_VERSION=\"${PKG_VERSION:-unknown}\""
        echo "PKG_LIBC=\"$libc\""
        echo "PKG_TARBALL=\"$PKG_TARBALL\""
        echo -n "PKG_DEPS=\""
        read_deps_file "${pdir}/${pkg}.deps" | tr '\n' ' '
        echo "\""
    } > "$meta"

    run_hook_dir "post_install" "$post_dir" "$rootfs" "$cat" "$pkg" "$libc" "$PKG_VERSION"

    log_success "Instalado ${cat}/${pkg} (${PKG_VERSION:-?}, ${libc})"
}

cmd_uninstall() {
    local name="$1"
    local libc
    libc="$(detect_libc "${2:-}")"
    local rootfs
    rootfs="$(rootfs_for_libc "$libc")"

    local resolved cat pkg pdir
    resolved="$(resolve_pkg_single "$name")"
    IFS='|' read -r cat pkg pdir <<< "$resolved"

    local meta filesdb
    meta="$(meta_path "$cat" "$pkg" "$libc")"
    filesdb="$(files_path "$cat" "$pkg" "$libc")"

    [ -f "$meta" ] || die "Pacote ${cat}/${pkg} (${libc}) não parece estar instalado (meta ausente)."
    [ -f "$filesdb" ] || die "Banco de arquivos ${filesdb} ausente, não posso desinstalar com segurança."

    # shellcheck disable=SC1090
    . "$meta"

    local target="${cat}/${pkg}"
    local rdeps
    rdeps="$(find_reverse_deps "$target" "$libc" || true)"

    if [ -n "$rdeps" ]; then
        log_error "Não é seguro remover ${target} (${libc}). Pacotes dependentes:"
        echo "$rdeps" >&2
        die "Remoção abortada para evitar quebrar dependências."
    fi

    local pre_dir="${pdir}/${pkg}.pre_uninstall"
    local post_dir="${pdir}/${pkg}.post_uninstall"

    run_hook_dir "pre_uninstall" "$pre_dir" "$rootfs" "$cat" "$pkg" "$libc" "${PKG_VERSION:-unknown}"

    log_info "Removendo arquivos de ${target} (${libc})"
    while read -r path; do
        [ -n "$path" ] || continue
        rm -f "${rootfs}/${path}" || log_warn "Falha ao remover ${rootfs}/${path}"
    done < "$filesdb"

    # tentar limpar diretórios vazios (best effort)
    sort -r "$filesdb" | while read -r path; do
        local dir
        dir="$(dirname "$path")"
        [ -n "$dir" ] || continue
        rmdir --ignore-fail-on-non-empty "${rootfs}/${dir}" 2>/dev/null || true
    done

    run_hook_dir "post_uninstall" "$post_dir" "$rootfs" "$cat" "$pkg" "$libc" "${PKG_VERSION:-unknown}"

    rm -f "$meta" "$filesdb"

    log_success "Removido ${target} (${libc})"
}

cmd_list() {
    printf "%-4s %-30s %-10s %-6s %-10s\n" "OK" "PACOTE" "VERSÃO" "LIBC" "CATEG."
    printf "%-4s %-30s %-10s %-6s %-10s\n" "----" "------" "-------" "----" "------"
    local meta
    for meta in "$DB_DIR"/*.meta; do
        [ -e "$meta" ] || continue
        unset PKG_ID PKG_NAME PKG_CATEGORY PKG_VERSION PKG_LIBC
        # shellcheck disable=SC1090
        . "$meta"
        printf "%-4s %-30s %-10s %-6s %-10s\n" \
            "[✔]" \
            "${PKG_ID:-?}" \
            "${PKG_VERSION:-?}" \
            "${PKG_LIBC:-?}" \
            "${PKG_CATEGORY:-?}"
    done
}

cmd_search() {
    local pattern="$1"
    ensure_repo
    [ -d "$PKG_BASE_DIR" ] || die "Diretório de pacotes não encontrado: $PKG_BASE_DIR"

    local found=0
    while IFS= read -r -d '' dir; do
        local pkg cat
        pkg="$(basename "$dir")"
        cat="$(basename "$(dirname "$dir")")"

        # case-insensitive match
        if [[ "${pkg,,}" == *"${pattern,,}"* ]]; then
            found=1
            local mark="[    ]"
            if pkg_is_installed_any_libc "$cat" "$pkg"; then
                mark="[ ✔️ ]"
            fi
            printf "%s %s/%s\n" "$mark" "$cat" "$pkg"
        fi
    done < <(find "$PKG_BASE_DIR" -mindepth 2 -maxdepth 2 -type d -print0)

    if [ "$found" -eq 0 ]; then
        log_warn "Nenhum pacote encontrado que corresponda a '$pattern'."
    fi
}

cmd_info() {
    local name="$1"
    ensure_repo
    [ -d "$PKG_BASE_DIR" ] || die "Diretório de pacotes não encontrado: $PKG_BASE_DIR"

    # Pode ser categoria/programa ou apenas programa
    local matches=()

    if [[ "$name" == */* ]]; then
        local cat="${name%/*}"
        local pkg="${name##*/}"
        local dir="${PKG_BASE_DIR}/${cat}/${pkg}"
        [ -d "$dir" ] || die "Pacote '$name' não encontrado."
        matches+=("${cat}|${pkg}|${dir}")
    else
        while IFS= read -r -d '' dir; do
            local pkg cat
            pkg="$(basename "$dir")"
            cat="$(basename "$(dirname "$dir")")"
            [ "$pkg" = "$name" ] || continue
            matches+=("${cat}|${pkg}|${dir}")
        done < <(find "$PKG_BASE_DIR" -mindepth 2 -maxdepth 2 -type d -print0)
    fi

    local count="${#matches[@]}"
    [ "$count" -gt 0 ] || die "Pacote '$name' não encontrado."

    local m
    for m in "${matches[@]}"; do
        IFS='|' read -r cat pkg dir <<< "$m"
        local installed mark
        if pkg_is_installed_any_libc "$cat" "$pkg"; then
            installed="sim"
            mark="[ ✔️ ]"
        else
            installed="não"
            mark="[    ]"
        fi

        printf "%s %s%s/%s%s\n" "$mark" "$BOLD" "$cat" "$pkg" "$RESET"
        printf "  Diretório:   %s\n" "$dir"

        # Mostrar infos por libc
        local meta
        local any_meta=0
        for meta in "${DB_DIR}/${cat}__${pkg}__"*.meta; do
            [ -f "$meta" ] || continue
            any_meta=1
            unset PKG_LIBC PKG_VERSION PKG_TARBALL
            # shellcheck disable=SC1090
            . "$meta"
            printf "  - libc:      %s\n" "${PKG_LIBC:-?}"
            printf "    versão:    %s\n" "${PKG_VERSION:-?}"
            printf "    tarball:   %s\n" "${PKG_TARBALL:-?}"
        done

        if [ "$any_meta" -eq 0 ]; then
            printf "  Instaldo?:   %s\n" "$installed"
        fi

        printf "  Script:      %s\n" "${dir}/${pkg}.sh"
        printf "\n"
    done
}

### MAIN #######################################################################

main() {
    local cmd="${1:-}"
    case "$cmd" in
        build)
            [ $# -ge 2 ] || { usage; exit 1; }
            check_requirements
            cmd_build "$2" "${3:-}"
            ;;
        install)
            [ $# -ge 2 ] || { usage; exit 1; }
            check_requirements
            cmd_install "$2" "${3:-}"
            ;;
        uninstall)
            [ $# -ge 2 ] || { usage; exit 1; }
            check_requirements
            cmd_uninstall "$2" "${3:-}"
            ;;
        list)
            cmd_list
            ;;
        search)
            [ $# -ge 2 ] || { usage; exit 1; }
            cmd_search "$2"
            ;;
        info)
            [ $# -ge 2 ] || { usage; exit 1; }
            cmd_info "$2"
            ;;
        update-repo)
            check_requirements
            cmd_update_repo
            ;;
        ""|-h|--help|help)
            usage
            ;;
        *)
            log_error "Comando inválido: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
