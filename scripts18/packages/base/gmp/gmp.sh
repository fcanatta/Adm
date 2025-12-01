#!/usr/bin/env bash
set -euo pipefail

PKG_NAME="gmp"
PKG_VERSION="6.3.0"
PKG_TARBALL="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_URL="https://ftp.gnu.org/gnu/gmp/${PKG_TARBALL}"
PKG_SHA256="a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"

# LFS_SOURCES_DIR deve estar definido pelo adm
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
            error "ADM_PROFILE='${profile}' não suportado para ${PKG_NAME}. Use glibc-final ou musl-final dentro do chroot correto."
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

    # Fix oficial do LFS para GCC-15+: sed em configure
    # (necessário para compilar corretamente com gcc-15.x) 
    sed -i '/long long t1;/,+1s/()/(...)/' configure
}

configure_build() {
    select_profile
    log "Configurando ${PKG_NAME}-${PKG_VERSION} para ${ADM_PROFILE}"

    ./configure \
        --prefix="${PREFIX}" \
        --enable-cxx \
        --disable-static \
        --docdir="${DOCDIR}"
}

build() {
    log "Compilando ${PKG_NAME}"
    make

    log "Gerando documentação HTML"
    make html
}

run_tests() {
    # Habilite testes com RUN_GMP_TESTS=1
    if [[ "${RUN_GMP_TESTS:-0}" = "1" ]]; then
        log "Executando suíte de testes de ${PKG_NAME} (recomendado pelo LFS)"
        make check 2>&1 | tee gmp-check-log || {
            error "Testes do GMP falharam. Verifique gmp-check-log."
        }
        if command -v awk >/dev/null 2>&1; then
            local passed
            passed="$(awk '/# PASS:/{total+=$3} END{print total+0}' gmp-check-log)"
            log "Total de testes PASS: ${passed}"
        fi
    else
        log "RUN_GMP_TESTS!=1 – pulando testes de ${PKG_NAME} (NÃO recomendado em produção)"
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
