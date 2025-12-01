#!/usr/bin/env bash
# Build Binutils-2.45.1 para o adm
# - Suporta dois perfis via ADM_PROFILE:
#     glibc-final  → Binutils final nativo (LFS-style)
#     musl-final   → Binutils alvo *-linux-musl (toolchain musl-native)
#
# O perfil padrão vem de /etc/adm.conf:
#   ADM_PROFILE="glibc-final"
# ou
#   ADM_PROFILE="musl-final"

set -euo pipefail

: "${LFS:?Variável LFS não definida}"
: "${LFS_SOURCES_DIR:?Variável LFS_SOURCES_DIR não definida}"

PKG_NAME="binutils"
PKG_VER="2.45.1"
PKG_DIR="${PKG_NAME}-${PKG_VER}"
TARBALL="${PKG_DIR}.tar.xz"
URL="https://ftp.gnu.org/gnu/binutils/${TARBALL}"

# MD5 opcional: deixe vazio ou preencha se quiser validar
TARBALL_MD5=""

SRC_DIR="${LFS_SOURCES_DIR}"
PKG_SRC_DIR="${SRC_DIR}/${PKG_DIR}"

log()   { echo "==> [${PKG_NAME}] $*"; }
error() { echo "ERRO [${PKG_NAME}]: $*" >&2; exit 1; }

# -------------------------------------------------------------
#  Seleção de perfil (glibc-final / musl-final)
# -------------------------------------------------------------

select_profile() {
    local profile="${ADM_PROFILE:-glibc-final}"

    case "$profile" in
        glibc-final)
            BUILD_MODE="glibc-final"
            # Binutils nativo (sem --target), glibc
            BIN_TARGET=""                           # nativo
            BIN_PREFIX="${ADM_PREFIX:-/usr}"
            BIN_SYSROOT="${ADM_SYSROOT:-/}"
            ;;

        musl-final)
            BUILD_MODE="musl-final"
            # Binutils para alvo *-linux-musl
            BIN_TARGET="${ADM_TGT:-$(uname -m)-linux-musl}"
            BIN_PREFIX="${ADM_PREFIX:-/usr}"
            BIN_SYSROOT="${ADM_SYSROOT:-/}"
            ;;

        *)
            error "ADM_PROFILE='$profile' desconhecido. Use 'glibc-final' ou 'musl-final'."
            ;;
    esac

    log "Perfil selecionado: ${profile} (BUILD_MODE=${BUILD_MODE})"
    log "  BIN_PREFIX = ${BIN_PREFIX}"
    log "  BIN_TARGET = ${BIN_TARGET:-<nativo>}"
    log "  BIN_SYSROOT= ${BIN_SYSROOT}"
}

# -------------------------------------------------------------
#  Funções utilitárias (download, checksum, extração)
# -------------------------------------------------------------

fetch_tarball() {
    mkdir -p "${SRC_DIR}"

    local dst="${SRC_DIR}/${TARBALL}"
    if [[ -f "${dst}" ]]; then
        log "Tarball já existe: ${dst}"
        return 0
    fi

    log "Baixando ${TARBALL} de ${URL} ..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL -o "${dst}" "${URL}" \
            || error "falha ao baixar ${URL} com curl"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${dst}" "${URL}" \
            || error "falha ao baixar ${URL} com wget"
    else
        error "nem curl nem wget encontrados para baixar o tarball"
    fi
}

check_md5() {
    local file="${SRC_DIR}/${TARBALL}"

    [[ -n "${TARBALL_MD5}" ]] || {
        log "TARBALL_MD5 vazio; pulando verificação de MD5."
        return 0
    }

    if ! command -v md5sum >/dev/null 2>&1; then
        log "md5sum não encontrado; não será feita verificação."
        return 0
    fi

    if [[ ! -f "${file}" ]]; then
        error "arquivo ${file} não existe para verificar MD5"
    fi

    log "Verificando MD5 de ${file} ..."
    local expected actual
    expected="${TARBALL_MD5}"
    actual="$(md5sum "${file}" | awk '{print $1}')"

    if [[ "${actual}" != "${expected}" ]]; then
        error "MD5 incorreto para ${file}
  Esperado: ${expected}
  Obtido..: ${actual}
Apague o tarball e tente novamente."
    fi

    log "MD5 OK (${actual})"
}

ensure_source_dir() {
    if [[ -d "${PKG_SRC_DIR}" ]]; then
        log "Diretório de fontes já existe: ${PKG_SRC_DIR}"
        return 0
    fi

    fetch_tarball
    check_md5

    log "Extraindo ${TARBALL} em ${SRC_DIR} ..."
    tar -xf "${SRC_DIR}/${TARBALL}" -C "${SRC_DIR}"

    if [[ ! -d "${PKG_SRC_DIR}" ]]; then
        error "diretório ${PKG_SRC_DIR} não encontrado após extração"
    fi
}

# -------------------------------------------------------------
#  Configuração de acordo com o perfil
# -------------------------------------------------------------

configure_binutils() {
    cd "${PKG_SRC_DIR}"

    rm -rf build
    mkdir -v build
    cd build

    log "Configurando Binutils-${PKG_VER} (BUILD_MODE=${BUILD_MODE}) ..."

    case "$BUILD_MODE" in
        glibc-final)
            # Binutils final nativo (estilo LFS)
            ../configure \
                --prefix="${BIN_PREFIX}" \
                --build="$(../config.guess)" \
                --enable-gold \
                --enable-ld=default \
                --enable-plugins \
                --enable-shared \
                --enable-64-bit-bfd \
                --disable-werror \
                --with-system-zlib
            ;;

        musl-final)
            # Binutils para alvo *-linux-musl
            ../configure \
                --prefix="${BIN_PREFIX}" \
                --target="${BIN_TARGET}" \
                --build="$(../config.guess)" \
                --with-sysroot="${BIN_SYSROOT}" \
                --enable-gold \
                --enable-ld=default \
                --enable-plugins \
                --enable-shared \
                --enable-64-bit-bfd \
                --disable-werror \
                --with-system-zlib \
                --disable-nls
            ;;

        *)
            error "BUILD_MODE='${BUILD_MODE}' inválido em configure_binutils"
            ;;
    esac
}

build_binutils() {
    cd "${PKG_SRC_DIR}/build"
    log "Compilando Binutils ..."
    make
}

install_binutils() {
    cd "${PKG_SRC_DIR}/build"

    log "Instalando Binutils em ${BIN_PREFIX} ..."
    make install

    # Ajuste clássico de ld como no LFS (apenas para glibc-final nativo)
    if [[ "${BUILD_MODE}" == "glibc-final" ]]; then
        log "Recompilando ld com LIB_PATH=/usr/lib:/lib e substituindo /usr/bin/ld ..."
        make -C ld clean
        make -C ld LIB_PATH=/usr/lib:/lib
        cp -v ld/ld-new /usr/bin/ld
    fi

    # Strip opcional
    if command -v strip >/dev/null 2>&1; then
        log "Executando strip em binários e libs de ${BIN_PREFIX} ..."
        find "${BIN_PREFIX}/bin" -type f -perm -u+x -exec strip --strip-all '{}' \; 2>/dev/null || true
        if [[ -n "${BIN_TARGET:-}" ]]; then
            find "${BIN_PREFIX}/${BIN_TARGET}/bin" -type f -perm -u+x -exec strip --strip-all '{}' \; 2>/dev/null || true
        fi
        find "${BIN_PREFIX}/lib" -type f -name '*.a' -exec strip --strip-debug '{}' \; 2>/dev/null || true
        find "${BIN_PREFIX}/lib" -type f -name '*.so*' -exec strip --strip-unneeded '{}' \; 2>/dev/null || true
    else
        log "strip não encontrado; pulando etapa de strip."
    fi
}

main() {
    log "Iniciando build de ${PKG_NAME}-${PKG_VER}"

    select_profile
    ensure_source_dir
    configure_binutils
    build_binutils
    install_binutils

    log "Binutils-${PKG_VER} instalado com sucesso (BUILD_MODE=${BUILD_MODE})."
}

main "$@"
