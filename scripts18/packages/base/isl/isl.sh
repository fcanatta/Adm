#!/usr/bin/env bash
set -euo pipefail

PKG_NAME="isl"
PKG_VERSION="0.27"
PKG_TARBALL="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_URL="https://sourceforge.net/projects/libisl/files/${PKG_TARBALL}"
PKG_SHA256="6d8babb59e7b672e8cb7870e874f3f7b813b6e00e6af3f8b04f7579965643d5"

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
        --docdir="${DOCDIR}"
}

build() {
    log "Compilando ${PKG_NAME}"
    make
}

run_tests() {
    # ISL não tem test-suite crítico no LFS; deixe opcional
    if [[ "${RUN_ISL_TESTS:-0}" = "1" ]]; then
        if make help 2>&1 | grep -qE '\bcheck\b'; then
            log "Executando testes de ${PKG_NAME}"
            make check || error "Testes do ISL falharam"
        else
            log "Makefile não fornece alvo 'check' – nenhum teste a executar"
        fi
    else
        log "RUN_ISL_TESTS!=1 – pulando testes de ${PKG_NAME}"
    fi
}

install_pkg() {
    log "Instalando ${PKG_NAME}"
    make install

    # Instala docs adicionais conforme LFS
    install -vd "${DOCDIR}"
    install -m644 doc/{CodingStyle,manual.pdf,SubmittingPatches,user.pod} \
        "${DOCDIR}" || log "Alguns arquivos de doc não encontrados, ignorando."

    # Corrige localização do script de auto-load do gdb (se existir)
    if compgen -G "/usr/lib/libisl*gdb.py" >/dev/null 2>&1; then
        mkdir -pv /usr/share/gdb/auto-load/usr/lib
        mv -v /usr/lib/libisl*gdb.py /usr/share/gdb/auto-load/usr/lib
    fi
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
