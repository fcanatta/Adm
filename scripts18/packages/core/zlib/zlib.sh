#!/usr/bin/env bash
# Build zlib-1.3.1 para o adm
#
# Baseado no LFS (8.6 Zlib-1.3.1):
#   ./configure --prefix=/usr
#   make
#   make check
#   make install
#   rm -fv /usr/lib/libz.a
#
# Adaptações:
#   - Perfis ADM_PROFILE=glibc-final | musl-final
#   - Download + verificação SHA256
#   - Empacotamento em tar.zst via DESTDIR separado

set -euo pipefail

PKG_NAME="zlib"
PKG_VERSION="1.3.1"
PKG_TARBALL="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_URL="https://zlib.net/${PKG_TARBALL}"

# SHA256 oficial do zlib-1.3.1.tar.gz
PKG_SHA256="9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"

# Precisa vir do adm (chroot já exporta isso)
: "${LFS_SOURCES_DIR:?LFS_SOURCES_DIR não definido}"

log() {
    printf '[%s] %s\n' "${PKG_NAME}" "$*" >&2
}

error() {
    printf '[%s:ERRO] %s\n' "${PKG_NAME}" "$*" >&2
    exit 1
}

PREFIX=""
BUILD_DIR=""

# -------------------------------------------------------------
# Seleção de perfil (glibc-final / musl-final)
# -------------------------------------------------------------

select_profile() {
    local profile="${ADM_PROFILE:-}"

    case "${profile}" in
        glibc-final|musl-final)
            PREFIX="/usr"
            ;;
        "")
            # Sem perfil definido: ainda assim funciona para zlib, mas avisamos.
            PREFIX="/usr"
            log "ADM_PROFILE não definido; usando PREFIX=${PREFIX} (comportamento padrão)."
            ;;
        *)
            error "ADM_PROFILE='${profile}' não suportado para ${PKG_NAME}.
Use glibc-final ou musl-final dentro do chroot apropriado."
            ;;
    esac

    log "Perfil selecionado: ${profile:-<padrão>}"
    log "  PREFIX = ${PREFIX}"
}

# -------------------------------------------------------------
# Download e verificação
# -------------------------------------------------------------

fetch_tarball() {
    cd "${LFS_SOURCES_DIR}"

    if [[ -f "${PKG_TARBALL}" ]]; then
        log "Tarball já existe: ${PKG_TARBALL}"
        return
    fi

    log "Baixando ${PKG_TARBALL} de ${PKG_URL}"
    if command -v curl >/dev/null 2>&1; then
        curl -fL -o "${PKG_TARBALL}.tmp" "${PKG_URL}"
        mv "${PKG_TARBALL}.tmp" "${PKG_TARBALL}"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${PKG_TARBALL}.tmp" "${PKG_URL}"
        mv "${PKG_TARBALL}.tmp" "${PKG_TARBALL}"
    else
        error "nem curl nem wget encontrados para baixar ${PKG_TARBALL}"
    fi
}

check_sha256() {
    cd "${LFS_SOURCES_DIR}"

    if [[ -z "${PKG_SHA256}" ]]; then
        log "PKG_SHA256 vazio; pulando verificação de SHA256 (por sua conta e risco)"
        return
    fi

    if ! command -v sha256sum >/dev/null 2>&1; then
        log "sha256sum não encontrado; pulando verificação de SHA256 (por sua conta e risco)"
        return
    fi

    if [[ ! -f "${PKG_TARBALL}" ]]; then
        error "tarball ${PKG_TARBALL} não existe para verificação"
    fi

    log "Verificando SHA256 de ${PKG_TARBALL}"
    local sum
    sum="$(sha256sum "${PKG_TARBALL}" | awk '{print $1}')"
    if [[ "${sum}" != "${PKG_SHA256}" ]]; then
        error "SHA256 inválido para ${PKG_TARBALL}:
  esperado: ${PKG_SHA256}
  obtido : ${sum}"
    fi
}

# -------------------------------------------------------------
# Preparar fonte e build
# -------------------------------------------------------------

prepare_source() {
    cd "${LFS_SOURCES_DIR}"
    rm -rf "${PKG_NAME}-${PKG_VERSION}"
    tar -xf "${PKG_TARBALL}"
    BUILD_DIR="${LFS_SOURCES_DIR}/${PKG_NAME}-${PKG_VERSION}"
    cd "${PKG_NAME}-${PKG_VERSION}"
}

configure_build() {
    if [[ -z "${BUILD_DIR:-}" || ! -d "${BUILD_DIR:-}" ]]; then
        error "BUILD_DIR não definido ou inexistente; rode prepare_source antes."
    fi

    cd "${BUILD_DIR}"
    log "Configurando ${PKG_NAME}-${PKG_VERSION}"
    ./configure --prefix="${PREFIX}"
}

build() {
    if [[ -z "${BUILD_DIR:-}" || ! -d "${BUILD_DIR:-}" ]]; then
        error "BUILD_DIR não definido ou inexistente; rode prepare_source antes."
    fi

    cd "${BUILD_DIR}"
    log "Compilando ${PKG_NAME}"
    make
}

run_tests() {
    if [[ -z "${BUILD_DIR:-}" || ! -d "${BUILD_DIR:-}" ]]; then
        error "BUILD_DIR não definido ou inexistente; rode prepare_source antes."
    fi

    cd "${BUILD_DIR}"

    # Testes opcionais, habilite com RUN_ZLIB_TESTS=1
    if [[ "${RUN_ZLIB_TESTS:-0}" = "1" ]]; then
        log "Executando testes de ${PKG_NAME} (make check)"
        make check || error "Testes do zlib falharam"
    else
        log "RUN_ZLIB_TESTS!=1 – pulando testes de ${PKG_NAME}"
    fi
}

install_pkg() {
    if [[ -z "${BUILD_DIR:-}" || ! -d "${BUILD_DIR:-}" ]]; then
        error "BUILD_DIR não definido ou inexistente; rode prepare_source antes."
    fi

    cd "${BUILD_DIR}"

    log "Instalando ${PKG_NAME} em ${PREFIX}"

    make install

    # LFS remove a lib estática, não é usada no sistema final
    if [[ -f "${PREFIX}/lib/libz.a" ]]; then
        log "Removendo biblioteca estática ${PREFIX}/lib/libz.a"
        rm -fv "${PREFIX}/lib/libz.a"
    fi
}

# -------------------------------------------------------------
# Empacotamento em tar.zst via DESTDIR
# -------------------------------------------------------------

package_zlib() {
    # Reinstala o zlib em um DESTDIR limpo usando make DESTDIR=...
    # e gera um tar.zst contendo só os arquivos deste pacote.

    local bin_dir destdir arch pkgfile

    if [[ -z "${BUILD_DIR:-}" || ! -d "${BUILD_DIR:-}" ]]; then
        log "BUILD_DIR não definido ou inexistente; não é possível empacotar."
        return 0
    fi

    bin_dir="${ADM_BIN_PKG_DIR:-${LFS:-/mnt/lfs}/binary-packages}"
    mkdir -p "${bin_dir}"

    destdir="$(mktemp -d "${TMPDIR:-/tmp}/${PKG_NAME}-pkg.XXXXXX")"

    log "Reinstalando ${PKG_NAME}-${PKG_VERSION} em DESTDIR para empacotamento..."
    (
        cd "${BUILD_DIR}"
        if ! make DESTDIR="${destdir}" install; then
            log "make DESTDIR=${destdir} install falhou; removendo DESTDIR e abortando empacotamento."
            rm -rf "${destdir}"
            # sair apenas do subshell com sucesso; a lógica externa trata como "nada a empacotar"
            exit 0
        fi

        # Remover lib estática também do pacote binário, para ficar
        # consistente com o sistema (sem /usr/lib/libz.a)
        if [[ -f "${destdir}${PREFIX}/lib/libz.a" ]]; then
            rm -fv "${destdir}${PREFIX}/lib/libz.a"
        fi
    )

    # Se não instalou nada, não gera pacote
    if [[ ! -d "${destdir}${PREFIX}" ]]; then
        log "Nenhum conteúdo em ${destdir}${PREFIX}; nada para empacotar."
        rm -rf "${destdir}"
        return 0
    fi

    arch="$(uname -m)"
    pkgfile="${bin_dir}/${PKG_NAME}-${PKG_VERSION}-${arch}.tar.zst"

    if command -v zstd >/dev/null 2>&1; then
        log "Empacotando ${PKG_NAME}-${PKG_VERSION} em ${pkgfile} ..."
        tar -C "${destdir}" -cf - . | zstd -T0 -19 -o "${pkgfile}.tmp"
        mv -f "${pkgfile}.tmp" "${pkgfile}"
        log "Pacote binário gerado: ${pkgfile}"
    else
        log "zstd não encontrado; pulando empacotamento em .tar.zst (apenas instalação no sistema)."
    fi

    rm -rf "${destdir}"
}

main() {
    select_profile
    fetch_tarball
    check_sha256
    prepare_source
    configure_build
    build
    run_tests
    install_pkg
    package_zlib

    log "Concluído ${PKG_NAME}-${PKG_VERSION} para perfil ${ADM_PROFILE:-<não-definido>}."
}

main "$@"
