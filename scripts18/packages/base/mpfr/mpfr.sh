#!/usr/bin/env bash
set -euo pipefail

PKG_NAME="mpfr"
PKG_VERSION="4.2.2"
PKG_TARBALL="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_URL="https://ftp.gnu.org/gnu/mpfr/${PKG_TARBALL}"
PKG_SHA256="b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01"

: "${LFS_SOURCES_DIR:?LFS_SOURCES_DIR não definido}"

log() {
    printf '[%s] %s\n' "${PKG_NAME}" "$*" >&2
}

error() {
    printf '[%s:ERRO] %s\n' "${PKG_NAME}" "$*" >&2
    exit 1
}

select_profile() {
    local profile="${ADM_PROFILE:-}"
    case "${profile}" in
        glibc-final|musl-final)
            PREFIX="/usr"
            DOCDIR="/usr/share/doc/${PKG_NAME}-${PKG_VERSION}"
            ;;
        *)
            error "ADM_PROFILE='${profile}' não suportado para ${PKG_NAME}. Use glibc-final ou musl-final."
            ;;
    esac
}

fetch_tarball() {
    cd "${LFS_SOURCES_DIR}"
    if [[ -f "${PKG_TARBALL}" ]]; then
        log "Tarball já existe: ${PKG_TARBALL}"
    else
        log "Baixando ${PKG_TARBALL} de ${PKG_URL}"
        if command -v curl >/dev/null 2>&1; then
            curl -L -o "${PKG_TARBALL}.tmp" "${PKG_URL}"
            mv "${PKG_TARBALL}.tmp" "${PKG_TARBALL}"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "${PKG_TARBALL}.tmp" "${PKG_URL}"
            mv "${PKG_TARBALL}.tmp" "${PKG_TARBALL}"
        else
            error "nem curl nem wget encontrados para baixar ${PKG_TARBALL}"
        fi
    fi
}

check_sha256() {
    cd "${LFS_SOURCES_DIR}"
    log "Verificando SHA256 de ${PKG_TARBALL}"
    local sum
    sum="$(sha256sum "${PKG_TARBALL}" | awk '{print $1}')"
    if [[ "${sum}" != "${PKG_SHA256}" ]]; then
        error "SHA256 inválido para ${PKG_TARBALL}: esperado ${PKG_SHA256}, obtido ${sum}"
    fi
}

prepare_source() {
    cd "${LFS_SOURCES_DIR}"
    rm -rf "${PKG_NAME}-${PKG_VERSION}"
    tar -xf "${PKG_TARBALL}"
    cd "${PKG_NAME}-${PKG_VERSION}"
}

configure_build() {
    select_profile
    log "Configurando ${PKG_NAME}-${PKG_VERSION} para ${ADM_PROFILE}"

    ./configure \
        --prefix="${PREFIX}" \
        --disable-static \
        --enable-thread-safe \
        --docdir="${DOCDIR}"
}

build() {
    log "Compilando ${PKG_NAME}"
    make

    log "Gerando documentação HTML"
    make html
}

run_tests() {
    # Habilite com RUN_MPFR_TESTS=1 (recomendado pelo LFS)
    if [[ "${RUN_MPFR_TESTS:-0}" = "1" ]]; then
        log "Executando suíte de testes de ${PKG_NAME}"
        make check || error "Testes do MPFR falharam"
    else
        log "RUN_MPFR_TESTS!=1 – pulando testes de ${PKG_NAME} (NÃO recomendado em produção)"
    fi
}

install_pkg() {
    log "Instalando ${PKG_NAME}"
    make install
    make install-html
}

main() {
    fetch_tarball
    check_sha256
    prepare_source
    configure_build
    build
    run_tests
    install_pkg
    log "Concluído ${PKG_NAME}-${PKG_VERSION} para perfil ${ADM_PROFILE:-<não-definido>}"
}

main "$@"
