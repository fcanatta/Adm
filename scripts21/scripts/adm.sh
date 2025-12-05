#!/usr/bin/env bash
# ADM - Simple Source-based Package Builder
# Constrói e instala programas a partir de scripts em /opt/adm/packages
# Suporte a perfis glibc / musl, cache de source e binário, hooks, deps, etc.

set -euo pipefail

umask 022

#########################
# Configuração global   #
#########################

ADM_ROOT="/opt/adm"
ADM_PACKAGES_DIR="$ADM_ROOT/packages"
ADM_PROFILES_DIR="$ADM_ROOT/profiles"
ADM_SOURCES_DIR="$ADM_ROOT/sources"
ADM_BUILD_DIR="$ADM_ROOT/build"
ADM_BINPKG_DIR="$ADM_ROOT/binpkgs"
ADM_LOG_DIR="$ADM_ROOT/log"
ADM_DB_DIR="$ADM_ROOT/db"
ADM_STATE_DIR="$ADM_ROOT/state"

# Ajuste para o seu repositório de scripts de construção
# (pode ser https, ssh, gitlab, github, etc)
ADM_REPO_URL="${ADM_REPO_URL:-git@gitlab.com:usuario/meu-adm-repo.git}"

# Perfil: glibc ou musl
ADM_PROFILE="${ADM_PROFILE:-glibc}"

case "$ADM_PROFILE" in
    glibc)
        ADM_ROOTFS="/opt/systems/glibc-rootfs"
        ;;
    musl)
        ADM_ROOTFS="/opt/systems/musl-rootfs"
        ;;
    *)
        echo "Perfil inválido em \$ADM_PROFILE: '$ADM_PROFILE' (use glibc ou musl)" >&2
        exit 1
        ;;
esac

export ADM_ROOT ADM_PACKAGES_DIR ADM_PROFILES_DIR ADM_SOURCES_DIR \
       ADM_BUILD_DIR ADM_BINPKG_DIR ADM_LOG_DIR ADM_DB_DIR ADM_STATE_DIR \
       ADM_PROFILE ADM_ROOTFS

#########################
# Cores e logging       #
#########################

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_INFO=$'\033[1;34m'
    C_WARN=$'\033[1;33m'
    C_ERR=$'\033[1;31m'
    C_OK=$'\033[1;32m'
else
    C_RESET=""
    C_INFO=""
    C_WARN=""
    C_ERR=""
    C_OK=""
fi

log_info() { echo "${C_INFO}[INFO]${C_RESET} $*"; }
log_warn() { echo "${C_WARN}[WARN]${C_RESET} $*"; }
log_err()  { echo "${C_ERR}[ERRO]${C_RESET} $*" >&2; }
log_ok()   { echo "${C_OK}[OK]${C_RESET} $*"; }

die() {
    log_err "$*"
    exit 1
}

#########################
# Utilitários           #
#########################

ensure_dirs() {
    mkdir -p \
        "$ADM_PACKAGES_DIR" \
        "$ADM_PROFILES_DIR" \
        "$ADM_SOURCES_DIR" \
        "$ADM_BUILD_DIR" \
        "$ADM_BINPKG_DIR" \
        "$ADM_LOG_DIR" \
        "$ADM_DB_DIR" \
        "$ADM_STATE_DIR"
}

# Carrega variáveis de um profile caso exista (toolchain, flags, etc)
load_profile_env() {
    local profile_file="$ADM_PROFILES_DIR/$ADM_PROFILE.profile"
    if [[ -f "$profile_file" ]]; then
        # shellcheck source=/dev/null
        . "$profile_file"
        log_info "Profile carregado: $profile_file"
    else
        log_warn "Profile $profile_file não encontrado; usando env padrão"
    fi
}

# Normaliza ID de pacote: categoria/programa
# Entrada pode ser "categoria/programa" (preferido).
parse_pkg_id() {
    local pkg_id="$1"
    if [[ "$pkg_id" != */* ]]; then
        die "ID de pacote deve ser categoria/programa (ex: core/bash)"
    fi
    ADM_PKG_CATEGORY="${pkg_id%%/*}"
    ADM_PKG_NAME="${pkg_id##*/}"
    ADM_PKG_DIR="$ADM_PACKAGES_DIR/$ADM_PKG_CATEGORY/$ADM_PKG_NAME"
    ADM_PKG_SCRIPT="$ADM_PKG_DIR/${ADM_PKG_NAME}.sh"
    [[ -f "$ADM_PKG_SCRIPT" ]] || die "Script de pacote não encontrado: $ADM_PKG_SCRIPT"
}

# Carrega script do pacote (metadados + funções pkg_build/pkg_install)
load_pkg_script() {
    local pkg_id="$1"
    parse_pkg_id "$pkg_id"
    # Limpa variáveis de pacote antigas
    unset PKG_NAME PKG_CATEGORY PKG_VERSION PKG_DESC PKG_HOMEPAGE \
          PKG_SOURCE PKG_CHECKSUMS PKG_CHECKSUM_TYPE PKG_DEPENDS
    unset -v PKG_SOURCE PKG_CHECKSUMS PKG_DEPENDS || true

    # shellcheck source=/dev/null
    . "$ADM_PKG_SCRIPT"

    PKG_NAME="${PKG_NAME:-$ADM_PKG_NAME}"
    PKG_CATEGORY="${PKG_CATEGORY:-$ADM_PKG_CATEGORY}"
    PKG_VERSION="${PKG_VERSION:-0}"
    PKG_DESC="${PKG_DESC:-Sem descrição}"
    PKG_HOMEPAGE="${PKG_HOMEPAGE:-}"
    PKG_CHECKSUM_TYPE="${PKG_CHECKSUM_TYPE:-sha256}"

    ADM_PKG_ID="$PKG_CATEGORY/$PKG_NAME"
    ADM_PKG_DB_DIR="$ADM_DB_DIR/$ADM_PKG_ID"
    ADM_PKG_LOG_FILE="$ADM_LOG_DIR/${PKG_CATEGORY}_${PKG_NAME}.log"
    ADM_PKG_WORKDIR="$ADM_BUILD_DIR/$PKG_CATEGORY/$PKG_NAME"
    ADM_PKG_DESTDIR="$ADM_PKG_WORKDIR/destdir"
    ADM_PKG_SRCWORK="$ADM_PKG_WORKDIR/src"

    mkdir -p "$ADM_PKG_DB_DIR" "$ADM_PKG_WORKDIR" "$ADM_PKG_DESTDIR" "$ADM_PKG_SRCWORK"
}

pkg_installed_mark() {
    [[ -f "$ADM_PKG_DB_DIR/installed" ]]
}

pkg_mark_installed() {
    date +"%Y-%m-%d %H:%M:%S" > "$ADM_PKG_DB_DIR/installed"
    echo "$PKG_VERSION" > "$ADM_PKG_DB_DIR/version"
}

pkg_mark_removed() {
    rm -f "$ADM_PKG_DB_DIR/installed"
}

pkg_manifest_file() {
    echo "$ADM_PKG_DB_DIR/files.lst"
}

pkg_last_success_file() {
    echo "$ADM_STATE_DIR/last_successful_build"
}

#########################
# Download de sources   #
#########################

# Detecta "tipo" de URL para tratamento
detect_source_type() {
    local url="$1"
    if [[ "$url" == git://* || "$url" == *.git || "$url" == ssh://*git* ]]; then
        echo "git"
    elif [[ "$url" == rsync://* ]]; then
        echo "rsync"
    elif [[ "$url" == http://* || "$url" == https://* ]]; then
        echo "http"
    elif [[ "$url" == ftp://* ]]; then
        echo "ftp"
    else
        echo "file"
    fi
}

# Verifica checksum se não for "SKIP"
check_checksum() {
    local file="$1"
    local expected="$2"
    local type="$3"

    [[ "$expected" == "SKIP" ]] && return 0

    if [[ "$type" == "sha256" ]]; then
        local got
        got=$(sha256sum "$file" | awk '{print $1}')
    else
        local got
        got=$(md5sum "$file" | awk '{print $1}')
    fi

    if [[ "$got" != "$expected" ]]; then
        log_err "Checksum mismatch para $file"
        log_err "Esperado: $expected"
        log_err "Obtido:  $got"
        return 1
    fi
    return 0
}

# Faz download em cache se não existir ou checksum inválido
download_one_source() {
    local url="$1"
    local checksum="$2"
    local ctype="$3" # md5 ou sha256
    local pkgcache_dir="$ADM_SOURCES_DIR/$PKG_CATEGORY/$PKG_NAME"

    mkdir -p "$pkgcache_dir"

    local base
    base=$(basename "$url")
    local dest="$pkgcache_dir/$base"

    if [[ -f "$dest" ]]; then
        if check_checksum "$dest" "$checksum" "$ctype"; then
            log_info "Source em cache OK: $dest"
            echo "$dest"
            return 0
        else
            log_warn "Removendo cache inválido: $dest"
            rm -f "$dest"
        fi
    fi

    local stype
    stype=$(detect_source_type "$url")

    log_info "Baixando source ($stype): $url"

    case "$stype" in
        git)
            # Clona em diretório separado, não em arquivo
            local gitdir="$pkgcache_dir/git-$(basename "$base" .git)"
            if [[ -d "$gitdir/.git" ]]; then
                (cd "$gitdir" && git fetch --all --prune && git pull --rebase) || \
                    die "Falha ao atualizar repositório git: $url"
            else
                git clone "$url" "$gitdir" || die "Falha ao clonar: $url"
            fi
            echo "$gitdir"
            return 0
            ;;
        rsync)
            rsync -av "$url" "$dest" || die "Falha rsync: $url"
            ;;
        http|ftp)
            if command -v curl >/dev/null 2>&1; then
                curl -L -o "$dest" "$url" || die "Falha curl: $url"
            else
                wget -O "$dest" "$url" || die "Falha wget: $url"
            fi
            ;;
        file)
            cp -a "$url" "$dest" || die "Falha ao copiar: $url"
            ;;
    esac

    check_checksum "$dest" "$checksum" "$ctype" || die "Checksum inválido após download: $dest"
    echo "$dest"
}

# Baixa todos os sources em paralelo quando forem arquivos de tar/zip; git é tratado à parte
download_all_sources() {
    local -n srcs_ref=$1   # array PKG_SOURCE
    local -n sums_ref=$2   # array PKG_CHECKSUMS
    local ctype="$3"

    local i url checksum
    local -a results=()
    local -a pids=()
    local -a tmpfiles=()

    if ((${#srcs_ref[@]} == 0)); then
        die "Pacote sem PKG_SOURCE definido"
    fi

    log_info "Iniciando downloads de source (possível paralelo)"

    for i in "${!srcs_ref[@]}"; do
        url="${srcs_ref[$i]}"
        checksum="${sums_ref[$i]:-SKIP}"

        # Para git: baixa síncrono (pois é diretório)
        if [[ "$(detect_source_type "$url")" == "git" ]]; then
            local gitdir
            gitdir=$(download_one_source "$url" "$checksum" "$ctype")
            results+=("$gitdir")
            continue
        fi

        # Para arquivos normais: roda em paralelo
        local tmpout
        tmpout="$(mktemp)"
        tmpfiles+=("$tmpout")

        (
            set -e
            dlfile=$(download_one_source "$url" "$checksum" "$ctype")
            echo "$dlfile" > "$tmpout"
        ) &
        pids+=("$!")
    done

    # Espera downloads em paralelo
    local ok=1
    for pid in "${pids[@]:-}"; do
        if ! wait "$pid"; then
            ok=0
        fi
    done

    ((ok == 1)) || die "Falha em um ou mais downloads de source"

    # Coleta arquivos
    for tmp in "${tmpfiles[@]:-}"; do
        if [[ -s "$tmp" ]]; then
            results+=("$(<"$tmp")")
        fi
        rm -f "$tmp"
    done

    # Exporta via variável global
    ADM_PKG_SOURCES_DOWNLOADED=("${results[@]}")
}

#########################
# Extração e patches    #
#########################

extract_one() {
    local src="$1"
    local dst="$2"

    mkdir -p "$dst"
    if [[ -d "$src/.git" ]]; then
        # Repositório git: copia para área de trabalho
        log_info "Usando diretório git como árvore de source: $src"
        rsync -a --delete "$src/" "$dst/" || die "Falha rsync git -> workdir"
        return 0
    fi

    case "$src" in
        *.tar.gz|*.tgz)
            tar -xzf "$src" -C "$dst" || die "Falha ao extrair $src"
            ;;
        *.tar.bz2|*.tbz2)
            tar -xjf "$src" -C "$dst" || die "Falha ao extrair $src"
            ;;
        *.tar.xz|*.txz)
            tar -xJf "$src" -C "$dst" || die "Falha ao extrair $src"
            ;;
        *.tar)
            tar -xf "$src" -C "$dst" || die "Falha ao extrair $src"
            ;;
        *.zip)
            unzip -q "$src" -d "$dst" || die "Falha ao extrair $src"
            ;;
        *)
            log_warn "Formato desconhecido, copiando arquivo simples: $src"
            cp -a "$src" "$dst/" || die "Falha ao copiar $src"
            ;;
    esac
}

apply_patches() {
    local patchdir="$ADM_PKG_DIR/patch"

    if [[ -d "$patchdir" ]]; then
        log_info "Aplicando patches de $patchdir"
        shopt -s nullglob
        local p
        for p in "$patchdir"/*.patch; do
            log_info "Aplicando patch: $(basename "$p")"
            patch -p1 < "$p" || die "Falha ao aplicar patch $p"
        done
        shopt -u nullglob
    fi
}

prepare_sources() {
    rm -rf "$ADM_PKG_SRCWORK"
    mkdir -p "$ADM_PKG_SRCWORK"

    local src
    for src in "${ADM_PKG_SOURCES_DOWNLOADED[@]}"; do
        extract_one "$src" "$ADM_PKG_SRCWORK"
    done

    # Se a extração criou apenas um subdiretório, entra nele
    local first_dir
    first_dir=$(find "$ADM_PKG_SRCWORK" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)
    if [[ -n "$first_dir" ]]; then
        ADM_PKG_SRCDIR="$first_dir"
    else
        ADM_PKG_SRCDIR="$ADM_PKG_SRCWORK"
    fi

    (cd "$ADM_PKG_SRCDIR" && apply_patches)
}

#########################
# Build / Install       #
#########################

run_with_log() {
    local log_file="$1"; shift
    mkdir -p "$(dirname "$log_file")"
    # log colorido na tela, puro no arquivo
    {
        echo "==== $(date) ===="
        echo "CMD: $*"
    } >> "$log_file"
    # shellcheck disable=SC2068
    "$@" 2>&1 | tee -a "$log_file"
}

do_pkg_build() {
    local pkg_id="$1"

    load_pkg_script "$pkg_id"
    load_profile_env

    log_info "=== BUILD $ADM_PKG_ID ($PKG_VERSION) para perfil $ADM_PROFILE ==="
    rm -rf "$ADM_PKG_WORKDIR"
    mkdir -p "$ADM_PKG_WORKDIR" "$ADM_PKG_DESTDIR" "$ADM_PKG_SRCWORK"

    # Baixa sources
    local -a PKG_SOURCE_ARR=()
    local -a PKG_CHECKSUMS_ARR=()

    # Converte variáveis para arrays nomeadas
    if declare -p PKG_SOURCE &>/dev/null; then
        # shellcheck disable=SC2178
        PKG_SOURCE_ARR=("${PKG_SOURCE[@]}")
    else
        die "Pacote $ADM_PKG_ID não definiu array PKG_SOURCE"
    fi

    if declare -p PKG_CHECKSUMS &>/dev/null; then
        # shellcheck disable=SC2178
        PKG_CHECKSUMS_ARR=("${PKG_CHECKSUMS[@]}")
    else
        # Se não houver, usa SKIP para todos
        PKG_CHECKSUMS_ARR=()
        local i
        for i in "${!PKG_SOURCE_ARR[@]}"; do
            PKG_CHECKSUMS_ARR+=("SKIP")
        done
    fi

    ADM_PKG_SOURCES_DOWNLOADED=()
    download_all_sources PKG_SOURCE_ARR PKG_CHECKSUMS_ARR "$PKG_CHECKSUM_TYPE"
    prepare_sources

    # Variáveis de ambiente para build/install
    export SRC_DIR="$ADM_PKG_SRCDIR"
    export BUILD_DIR="$ADM_PKG_WORKDIR"
    export DESTDIR="$ADM_PKG_DESTDIR"
    export ROOTFS="$ADM_ROOTFS"

    # Funções obrigatórias pkg_build & opcional pkg_install
    type pkg_build >/dev/null 2>&1 || die "Pacote $ADM_PKG_ID não definiu função pkg_build"

    run_with_log "$ADM_PKG_LOG_FILE" bash -c '
        set -euo pipefail
        cd "$SRC_DIR"
        pkg_build
        if type pkg_install >/dev/null 2>&1; then
            pkg_install
        else
            # fallback: make install DESTDIR se existir Makefile
            if [[ -f Makefile || -f makefile ]]; then
                make DESTDIR="$DESTDIR" install
            fi
        fi
    '

    log_ok "Build de $ADM_PKG_ID concluído"
}

# Empacota DESTDIR em binário tar.gz preservando permissões/links
create_binpkg() {
    local pkg_id="$1"

    load_pkg_script "$pkg_id"

    local binpkg="$ADM_BINPKG_DIR/${PKG_CATEGORY}_${PKG_NAME}-${PKG_VERSION}-${ADM_PROFILE}.tar.gz"
    mkdir -p "$ADM_BINPKG_DIR"

    (cd "$ADM_PKG_DESTDIR" && tar -czf "$binpkg" .) || die "Falha ao criar binpkg: $binpkg"
    log_ok "Binário em cache: $binpkg"
}

# Instala arquivos de DESTDIR em ROOTFS e gera manifest
install_destdir_to_rootfs() {
    local manifest
    manifest=$(pkg_manifest_file)

    mkdir -p "$ADM_ROOTFS" "$(dirname "$manifest")"
    : > "$manifest"

    # Usa rsync para preservar perms e links
    rsync -aHAX --numeric-ids "$ADM_PKG_DESTDIR"/ "$ADM_ROOTFS"/

    # Gera lista de arquivos instalados (relativos ao ROOTFS)
    (cd "$ADM_ROOTFS" && find . -mindepth 1 -type f -o -type l -o -type d) \
        | sed 's|^\./||' \
        > "$manifest"
}

run_hook_if_exists() {
    local hookname="$1" # pre_install, post_install, pre_uninstall, post_uninstall
    local script="$ADM_PKG_DIR/${ADM_PKG_NAME}.${hookname}"

    if [[ -x "$script" ]]; then
        log_info "Executando hook $hookname: $script"
        ROOTFS="$ADM_ROOTFS" DESTDIR="$ADM_PKG_DESTDIR" PkgID="$ADM_PKG_ID" "$script"
    elif [[ -f "$script" ]]; then
        log_info "Executando hook $hookname via sh: $script"
        ROOTFS="$ADM_ROOTFS" DESTDIR="$ADM_PKG_DESTDIR" PkgID="$ADM_PKG_ID" sh "$script"
    fi
}

do_pkg_install() {
    local pkg_id="$1"

    load_pkg_script "$pkg_id"
    load_profile_env

    if pkg_installed_mark; then
        log_warn "Pacote $ADM_PKG_ID já marcado como instalado; atualizando..."
    fi

    # Verifica se existe binário em cache
    local binpkg="$ADM_BINPKG_DIR/${PKG_CATEGORY}_${PKG_NAME}-${PKG_VERSION}-${ADM_PROFILE}.tar.gz"

    rm -rf "$ADM_PKG_WORKDIR"
    mkdir -p "$ADM_PKG_WORKDIR" "$ADM_PKG_DESTDIR"

    if [[ -f "$binpkg" ]]; then
        log_info "Usando binário em cache: $binpkg"
        (cd "$ADM_PKG_DESTDIR" && tar -xzf "$binpkg")
    else
        do_pkg_build "$pkg_id"
        create_binpkg "$pkg_id"
    fi

    run_hook_if_exists "pre_install"
    install_destdir_to_rootfs
    run_hook_if_exists "post_install"

    pkg_mark_installed
    echo "$ADM_PKG_ID" > "$(pkg_last_success_file)"

    log_ok "Instalação concluída: $ADM_PKG_ID"
}

do_pkg_uninstall() {
    local pkg_id="$1"

    load_pkg_script "$pkg_id"

    if ! pkg_installed_mark; then
        log_warn "Pacote $ADM_PKG_ID não está instalado"
        return 0
    fi

    run_hook_if_exists "pre_uninstall"

    local manifest
    manifest=$(pkg_manifest_file)
    if [[ -f "$manifest" ]]; then
        log_info "Removendo arquivos listados em manifest"
        while IFS= read -r f; do
            local full="$ADM_ROOTFS/$f"
            if [[ -e "$full" || -L "$full" ]]; then
                rm -rf "$full"
            fi
        done < "$manifest"
    else
        log_warn "Manifest não encontrado; não removendo arquivos de $ADM_PKG_ID"
    fi

    pkg_mark_removed
    run_hook_if_exists "post_uninstall"
    log_ok "Desinstalação concluída: $ADM_PKG_ID"
}

#########################
# Dependências          #
#########################

# Lê PKG_DEPENDS[] e resolve em ordem (simples, sem detecção de loop sofisticada)
resolve_deps_recursive() {
    local pkg_id="$1"
    local -n resolved=$2
    local -n seen=$3

    # Evita loops
    local s
    for s in "${seen[@]}"; do
        [[ "$s" == "$pkg_id" ]] && return 0
    done
    seen+=("$pkg_id")

    load_pkg_script "$pkg_id"

    local dep
    if declare -p PKG_DEPENDS &>/dev/null; then
        for dep in "${PKG_DEPENDS[@]}"; do
            [[ -z "$dep" ]] && continue
            resolve_deps_recursive "$dep" resolved seen
        done
    fi

    # Adiciona se ainda não estiver em resolved
    for s in "${resolved[@]}"; do
        [[ "$s" == "$pkg_id" ]] && return 0
    done
    resolved+=("$pkg_id")
}

resolve_deps_for_pkg() {
    local pkg_id="$1"
    local -a resolved=()
    local -a seen=()

    resolve_deps_recursive "$pkg_id" resolved seen

    # Remove o próprio no meio e garante que fique no fim
    local out=() p
    for p in "${resolved[@]}"; do
        [[ "$p" == "$pkg_id" ]] && continue
        out+=("$p")
    done
    out+=("$pkg_id")
    ADM_RESOLVED_DEPS=("${out[@]}")
}

install_with_deps() {
    local pkg_id="$1"
    resolve_deps_for_pkg "$pkg_id"

    log_info "Ordem de instalação (dependências):"
    local p
    for p in "${ADM_RESOLVED_DEPS[@]}"; do
        echo "  - $p"
    done

    for p in "${ADM_RESOLVED_DEPS[@]}"; do
        load_pkg_script "$p"
        if pkg_installed_mark; then
            log_ok "Já instalado: $p"
            continue
        fi
        do_pkg_install "$p"
    done
}

#########################
# Busca / Info / Lista  #
#########################

cmd_search() {
    local pattern="${1:-}"

    [[ -z "$pattern" ]] && die "Uso: adm.sh search <texto>"

    ensure_dirs

    log_info "Procurando por '$pattern' em $ADM_PACKAGES_DIR"

    while IFS= read -r script; do
        local cat name pkg_id
        name=$(basename "$script" .sh)
        cat=$(basename "$(dirname "$script")")
        pkg_id="$cat/$name"

        load_pkg_script "$pkg_id" 2>/dev/null || continue

        local mark=""
        if pkg_installed_mark; then
            mark=" [✔️]"
        else
            mark=""
        fi

        if [[ "$pkg_id" == *"$pattern"* || "$PKG_DESC" == *"$pattern"* ]]; then
            echo "$pkg_id$mark - $PKG_DESC"
        fi
    done < <(find "$ADM_PACKAGES_DIR" -type f -name "*.sh" | sort)
}

cmd_info() {
    local pkg_id="$1"
    [[ -z "$pkg_id" ]] && die "Uso: adm.sh info categoria/programa"

    load_pkg_script "$pkg_id"

    local mark="[ ]"
    if pkg_installed_mark; then
        mark="[✔️]"
    fi

    echo "Pacote:     $ADM_PKG_ID $mark"
    echo "Versão:     $PKG_VERSION"
    echo "Descrição:  $PKG_DESC"
    echo "Homepage:   ${PKG_HOMEPAGE:-<nenhum>}"
    echo "Perfil:     $ADM_PROFILE"
    echo "RootFS:     $ADM_ROOTFS"
    echo "Script:     $ADM_PKG_SCRIPT"
    echo "Depends:"

    if declare -p PKG_DEPENDS &>/dev/null; then
        local d
        for d in "${PKG_DEPENDS[@]}"; do
            echo "  - $d"
        done
    else
        echo "  <sem dependências>"
    fi
}

cmd_list_installed() {
    ensure_dirs
    log_info "Lista de pacotes instalados em $ADM_ROOTFS"
    find "$ADM_DB_DIR" -mindepth 2 -maxdepth 2 -type f -name "installed" \
        | sed "s|$ADM_DB_DIR/||; s|/installed||" \
        | sort \
        || true
}

#########################
# Limpeza               #
#########################

cmd_clean() {
    log_warn "Limpando diretórios de build e destdir..."
    rm -rf "$ADM_BUILD_DIR"
    mkdir -p "$ADM_BUILD_DIR"
    log_ok "Build limpo"

    log_warn "Limpando estado temporário..."
    rm -rf "$ADM_STATE_DIR"
    mkdir -p "$ADM_STATE_DIR"
    log_ok "Estado limpo (mantidos binpkgs, sources e db)"
}

#########################
# Rebuild último        #
#########################

cmd_rebuild_last() {
    local f
    f=$(pkg_last_success_file)

    if [[ ! -f "$f" ]]; then
        die "Nenhum build anterior registrado"
    fi

    local last
    last=$(<"$f")
    log_info "Rebuild do último pacote com sucesso: $last"
    do_pkg_build "$last"
    create_binpkg "$last"
    log_ok "Rebuild concluído: $last"
}

#########################
# Sync do repo          #
#########################

cmd_sync_repo() {
    ensure_dirs
    if [[ -d "$ADM_PACKAGES_DIR/.git" ]]; then
        log_info "Atualizando repositório existente em $ADM_PACKAGES_DIR"
        (cd "$ADM_PACKAGES_DIR" && git fetch --all --prune && git pull --rebase) \
            || die "Falha ao atualizar repositório de scripts"
    else
        log_info "Clonando repositório de scripts em $ADM_PACKAGES_DIR"
        rm -rf "$ADM_PACKAGES_DIR"
        mkdir -p "$(dirname "$ADM_PACKAGES_DIR")"
        git clone "$ADM_REPO_URL" "$ADM_PACKAGES_DIR" \
            || die "Falha ao clonar repositório $ADM_REPO_URL"
    fi
    log_ok "Repositório de scripts sincronizado"
}

#########################
# Ajuda / CLI           #
#########################

usage() {
    cat <<EOF
Uso: adm.sh <comando> [args]

Comandos principais:
  sync-repo
      Sincroniza /opt/adm/packages a partir de \$ADM_REPO_URL

  search <texto>
      Procura pacotes cujo ID ou descrição contém <texto>.
      Mostra [✔️] ao lado dos instalados.

  info <categoria/programa>
      Mostra informações completas do pacote, com [✔️] se instalado.

  list-installed
      Lista todos os pacotes instalados.

  build <categoria/programa>
      Constrói o pacote (source -> binpkg) para o perfil atual.

  install <categoria/programa>
      Resolve dependências e instala o pacote + deps no \$ADM_ROOTFS.

  uninstall <categoria/programa>
      Executa hooks de uninstall e remove arquivos registrados no manifest.

  rebuild-last
      Reconstrói o último pacote que foi construído com sucesso.

  clean
      Limpa diretórios de build e estado temporário (não remove binpkgs/sources/db).

Variáveis importantes:
  ADM_PROFILE   = glibc (padrão) ou musl
  ADM_ROOTFS    = /opt/systems/glibc-rootfs ou /opt/systems/musl-rootfs
  ADM_REPO_URL  = URL git do repositório de scripts de pacote
EOF
}

#########################
# Main                  #
#########################

main() {
    ensure_dirs

    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        sync-repo)
            cmd_sync_repo "$@"
            ;;
        search)
            cmd_search "$@"
            ;;
        info)
            cmd_info "$@"
            ;;
        list-installed)
            cmd_list_installed
            ;;
        build)
            [[ $# -gt 0 ]] || die "Uso: adm.sh build categoria/programa"
            do_pkg_build "$1"
            create_binpkg "$1"
            ;;
        install)
            [[ $# -gt 0 ]] || die "Uso: adm.sh install categoria/programa"
            install_with_deps "$1"
            ;;
        uninstall)
            [[ $# -gt 0 ]] || die "Uso: adm.sh uninstall categoria/programa"
            do_pkg_uninstall "$1"
            ;;
        rebuild-last)
            cmd_rebuild_last
            ;;
        clean)
            cmd_clean
            ;;
        ""|-h|--help|help)
            usage
            ;;
        *)
            die "Comando desconhecido: $cmd"
            ;;
    esac
}

main "$@"
