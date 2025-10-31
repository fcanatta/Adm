#!/usr/bin/env bash
#=============================================================
# install.sh — Instalador de pacotes do ADM Build System
#-------------------------------------------------------------
# - Instala pacotes .pkg.tar.zst ou .pkg.tar.xz
# - Aceita nome de pacote ou caminho completo
# - Resolve dependências recursivamente
# - Se dependência não existir no cache, constrói com build.sh
# - Executa hooks pre/post-install
# - Valida integridade (SHA256) e assinatura GPG (opcional)
# - Atualiza status.db e logs
#=============================================================

set -o pipefail
[[ -n "${ADM_INSTALL_SH_LOADED}" ]] && return
ADM_INSTALL_SH_LOADED=1

#-------------------------------------------------------------
# Segurança e dependências
#-------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" && ! -f "/usr/src/adm/scripts/env.sh" ]]; then
    echo "❌ Este script deve ser executado dentro do ambiente ADM."
    exit 1
fi

# Dependências
source /usr/src/adm/scripts/env.sh
source /usr/src/adm/scripts/log.sh
source /usr/src/adm/scripts/utils.sh
source /usr/src/adm/scripts/ui.sh
source /usr/src/adm/scripts/hooks.sh
source /usr/src/adm/scripts/build.sh

#-------------------------------------------------------------
# Configurações globais
#-------------------------------------------------------------
PACKAGES_DIR="${ADM_ROOT}/packages"
STATUS_DB="${ADM_STATUS_DB:-/var/lib/adm/status.db}"
INSTALL_LOG_DIR="${ADM_LOG_DIR}/install"
ensure_dir "$INSTALL_LOG_DIR"
ensure_dir "$(dirname "$STATUS_DB")"

#-------------------------------------------------------------
# Funções auxiliares
#-------------------------------------------------------------

# Verifica se o pacote já está instalado
is_installed() {
    local pkg="$1"
    grep -q "^${pkg}|" "$STATUS_DB" 2>/dev/null
}

# Localiza um pacote no cache
find_package_file() {
    local name="$1"
    find "$PACKAGES_DIR" -type f -name "${name}-*.pkg.tar.*" | sort -V | tail -n1
}

# Lê metadados do pacote (.pkginfo)
load_pkginfo() {
    local pkginfo_file="$1"
    [[ ! -f "$pkginfo_file" ]] && abort_build "pkginfo não encontrado: $pkginfo_file"

    PKG_NAME=$(awk -F'= ' '/^pkgname/{print $2}' "$pkginfo_file")
    PKG_VERSION=$(awk -F'= ' '/^pkgver/{print $2}' "$pkginfo_file")
    PKG_DEPENDS=($(awk -F'= ' '/^depends/{for(i=2;i<=NF;i++)print $i}' "$pkginfo_file"))
    PKG_GROUP=$(awk -F'= ' '/^group/{print $2}' "$pkginfo_file")
    PKG_SHA=$(awk -F'= ' '/^sha256/{print $2}' "$pkginfo_file")
}

# Verifica integridade e assinatura
verify_integrity() {
    local pkgfile="$1"
    local pkginfo="$2"

    local expected_sha
    expected_sha=$(awk -F'= ' '/^sha256/{print $2}' "$pkginfo")

    local actual_sha
    actual_sha=$(sha256sum "$pkgfile" | awk '{print $1}')

    if [[ "$expected_sha" != "$actual_sha" ]]; then
        abort_build "Falha na integridade: SHA256 não corresponde para $pkgfile"
    fi

    if [[ -f "${pkgfile}.sig" && -n "${PKG_SIGN_KEY:-}" ]]; then
        if ! gpg --verify "${pkgfile}.sig" "$pkgfile" >/dev/null 2>&1; then
            abort_build "Assinatura GPG inválida para $pkgfile"
        fi
    fi

    log_success "Integridade e assinatura OK: $pkgfile"
}

# Extrai pacote no sistema
extract_package() {
    local pkgfile="$1"
    ui_draw_progress "${PKG_NAME}" "extract" 25 0
    tar --zstd -C / -xf "$pkgfile" >>"${INSTALL_LOG_DIR}/${PKG_NAME}.log" 2>&1 || abort_build "Falha ao extrair $pkgfile"
    ui_draw_progress "${PKG_NAME}" "extract" 100 1
}

# Registra no banco local
register_install() {
    local pkg="$1"
    local version="$2"
    local group="$3"
    local date
    date=$(date '+%Y-%m-%d %H:%M:%S')
    printf "%s|%s|%s|%s|installed\n" "$pkg" "$version" "$group" "$date" >>"$STATUS_DB"
}

#-------------------------------------------------------------
# Instalação de um único pacote (sem resolver dependências)
#-------------------------------------------------------------
install_single_package() {
    local pkgfile="$1"

    local pkgdir
    pkgdir=$(dirname "$pkgfile")
    local pkginfo="${pkgdir}/$(basename "$pkgfile" .pkg.tar.zst).pkginfo"
    [[ ! -f "$pkginfo" ]] && pkginfo="${pkgdir}/$(basename "$pkgfile" .pkg.tar.xz).pkginfo"

    load_pkginfo "$pkginfo"

    if is_installed "$PKG_NAME"; then
        log_warn "Pacote $PKG_NAME já está instalado. Pulando."
        return 0
    fi

    ui_draw_header "$PKG_NAME-$PKG_VERSION" "install"
    call_hook "pre-install" "$pkgdir"

    verify_integrity "$pkgfile" "$pkginfo"
    extract_package "$pkgfile"
    register_install "$PKG_NAME" "$PKG_VERSION" "$PKG_GROUP"

    call_hook "post-install" "$pkgdir"
    log_success "Instalação concluída: $PKG_NAME-$PKG_VERSION"
}

#-------------------------------------------------------------
# Resolve dependências e instala em ordem correta
#-------------------------------------------------------------
install_with_deps() {
    local target="$1"

    # Detectar se argumento é nome ou caminho
    local pkgfile=""
    if [[ -f "$target" ]]; then
        pkgfile="$target"
    else
        pkgfile=$(find_package_file "$target")
        if [[ -z "$pkgfile" ]]; then
            log_warn "Pacote $target não encontrado em cache. Tentando construir..."
            local build_dir
            build_dir=$(find "$ADM_REPO_DIR" -type f -name "build.pkg" -exec grep -l "PKG_NAME=\"$target\"" {} \; | xargs -r dirname | head -n1)
            if [[ -z "$build_dir" ]]; then
                abort_build "Não foi possível localizar fonte para $target"
            fi
            build_package "$build_dir" || abort_build "Falha ao construir $target"
            pkgfile=$(find_package_file "$target")
        fi
    fi

    # Carregar pkginfo
    local pkgdir
    pkgdir=$(dirname "$pkgfile")
    local pkginfo="${pkgdir}/$(basename "$pkgfile" .pkg.tar.zst).pkginfo"
    [[ ! -f "$pkginfo" ]] && pkginfo="${pkgdir}/$(basename "$pkgfile" .pkg.tar.xz).pkginfo"

    load_pkginfo "$pkginfo"

    # Resolver dependências
    local deps=()
    for dep in "${PKG_DEPENDS[@]}"; do
        if ! is_installed "$dep"; then
            deps+=("$dep")
        fi
    done

    # Instalar dependências primeiro
    for dep in "${deps[@]}"; do
        install_with_deps "$dep"
    done

    # Agora instala o pacote principal
    install_single_package "$pkgfile"
}

#-------------------------------------------------------------
# Execução principal
#-------------------------------------------------------------
_show_help() {
    cat <<EOF
Uso:
  install.sh <pacote.pkg.tar.zst>     Instala um pacote a partir do arquivo
  install.sh <nome-do-pacote>         Instala um pacote pelo nome (busca no cache ou constrói)
  install.sh --test                   Instala zlib de exemplo
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    log_init
    case "$1" in
        --test)
            install_with_deps "zlib"
            ;;
        --help|-h)
            _show_help
            ;;
        *)
            [[ -z "$1" ]] && _show_help && exit 2
            install_with_deps "$1"
            ;;
    esac
    log_close
fi
