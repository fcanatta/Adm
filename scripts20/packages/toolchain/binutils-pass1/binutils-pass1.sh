#!/usr/bin/env bash
# Build script para Binutils-2.45.1 - Pass 1 (LFS-style), integrado ao adm
# Responsabilidade:
#   - baixar e extrair o source (usando ADM_CACHE_SRC)
#   - compilar
#   - instalar em ADM_DESTDIR
#   - definir ADM_PKG_VERSION
#
# Empacotamento e buildinfo são feitos pelo adm.sh (adm_finalize_build).

set -euo pipefail

# Definir quais libcs esse pacote suporta:
#   - para gcc final: glibc, musl, uclibc-ng
#   - para glibc: apenas glibc
#   - para musl: apenas musl
REQUIRED_LIBCS="glibc musl uclibc-ng"

# Carregar validador de profile
source /usr/src/adm/lib/adm_profile_validate.sh

# Validar profile atual
adm_profile_validate

ACTION="${1:-}"
LIBC="${2:-}"

if [ -z "${ACTION:-}" ]; then
    echo "Uso: $0 build <glibc|musl>" >&2
    exit 1
fi

if [ "$ACTION" != "build" ]; then
    echo "Ação inválida: $ACTION (somente 'build' é suportado)" >&2
    exit 1
fi

# Variáveis fornecidas pelo adm:
#   ADM_CATEGORY    -> ex: toolchain
#   ADM_PKG_NAME    -> ex: binutils-pass1
#   ADM_LIBC        -> glibc|musl
#   ADM_ROOTFS      -> rootfs alvo (usado como LFS)
#   ADM_CACHE_SRC   -> cache de sources
#   ADM_CACHE_PKG   -> cache de tarballs (não usado aqui)
#   ADM_BUILD_ROOT  -> diretório raíz de build (adm define)
#   ADM_DESTDIR     -> diretório onde devemos instalar (adm define)
#
# Empacotamento e ADM_BUILDINFO serão tratados fora daqui.

PKG_NAME="${ADM_PKG_NAME:-binutils-pass1}"
BINUTILS_VER="2.45.1"
ADM_PKG_VERSION="${BINUTILS_VER}-pass1"
export ADM_PKG_VERSION

# URL oficial (pode trocar para mirror se quiser)
PKG_SOURCE_URL="https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz"

# MD5 opcional (preencha se quiser verificar)
PKG_MD5=""

# Diretórios principais
CACHE_SRC="${ADM_CACHE_SRC:-/var/cache/adm/sources}"
BUILD_ROOT="${ADM_BUILD_ROOT:-/tmp/adm-build-toolchain-binutils-pass1-${ADM_LIBC:-unknown}}"
DESTDIR="${ADM_DESTDIR:-${BUILD_ROOT}/destdir}"
SRC_ARCHIVE="${CACHE_SRC}/binutils-${BINUTILS_VER}.tar.xz"
SRC_DIR="${BUILD_ROOT}/binutils-${BINUTILS_VER}"

log()  { printf "[%s] %s\n" "$(date +'%H:%M:%S')" "$*"; }
err()  { printf "[%s] [ERRO] %s\n" "$(date +'%H:%M:%S')" "$*" >&2; }

download_source() {
    mkdir -p "$CACHE_SRC"

    if [ -f "$SRC_ARCHIVE" ]; then
        log "Usando source em cache: $SRC_ARCHIVE"
    else
        log "Baixando Binutils ${BINUTILS_VER} de ${PKG_SOURCE_URL}..."
        if command -v curl >/dev/null 2>&1; then
            curl -L -o "$SRC_ARCHIVE" "$PKG_SOURCE_URL"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "$SRC_ARCHIVE" "$PKG_SOURCE_URL"
        else
            err "Nem curl nem wget encontrados para download."
            exit 1
        fi
    fi

    if [ -n "$PKG_MD5" ]; then
        log "Verificando MD5..."
        echo "${PKG_MD5}  ${SRC_ARCHIVE}" | md5sum -c - || {
            err "Falha na verificação de MD5 de ${SRC_ARCHIVE}"
            exit 1
        }
    else
        log "PKG_MD5 vazio, pulando verificação de checksum."
    fi
}

prepare_builddir() {
    rm -rf "$BUILD_ROOT"
    mkdir -p "$BUILD_ROOT" "$DESTDIR"

    log "Extraindo ${SRC_ARCHIVE} para ${BUILD_ROOT}..."
    tar -xf "$SRC_ARCHIVE" -C "$BUILD_ROOT"

    if [ ! -d "$SRC_DIR" ]; then
        err "Diretório de source esperado não encontrado: $SRC_DIR"
        exit 1
    fi

    cd "$SRC_DIR"
    mkdir -pv build
    cd build
}

do_build() {
    # LFS_TGT: triplet alvo; use um específico se já tiver (ex: x86_64-lfs-linux-gnu)
    export LFS_TGT="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"

    # Tratamos ADM_ROOTFS como LFS (sysroot da toolchain em construção)
    if [ -z "${ADM_ROOTFS:-}" ]; then
        err "ADM_ROOTFS não definido pelo adm (rootfs alvo)."
        exit 1
    fi
    export LFS="$ADM_ROOTFS"

    log "Configurando Binutils ${BINUTILS_VER} - Pass 1"
    log "  LFS (sysroot)   = ${LFS}"
    log "  LFS_TGT         = ${LFS_TGT}"
    log "  prefix (no alvo)= /tools"
    log "  DESTDIR         = ${DESTDIR}"

    # Profile de libc (glibc/musl) já foi carregado pelo adm
    # então CC, CFLAGS, LDFLAGS etc já estão presentes se definidos.

    ../configure \
        --prefix=/tools \
        --with-sysroot="${LFS}" \
        --target="${LFS_TGT}" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror \
        --enable-new-dtags \
        --enable-default-hash-style=gnu

    log "Rodando make (isso pode levar algum tempo)..."
    make

    log "Instalando no DESTDIR (${DESTDIR})..."
    make DESTDIR="${DESTDIR}" install

    log "Build e instalação em DESTDIR concluídos para ${PKG_NAME} (${ADM_PKG_VERSION})"
}

case "$ACTION" in
    build)
        download_source
        prepare_builddir
        do_build
        ;;
    *)
        err "Ação inválida: $ACTION"
        exit 1
        ;;
esac
