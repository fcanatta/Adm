#!/usr/bin/env bash
# Build script para GCC 15.2.0 - Pass 1, formato novo do ADM
# Responsabilidade:
#   - baixar e extrair o source
#   - preparar a build
#   - compilar gcc (C only) + libgcc
#   - instalar em ADM_DESTDIR
#   - definir ADM_PKG_VERSION
#
# Empacotamento e buildinfo são tratados por adm_finalize_build() no adm.sh.

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

if [ "$ACTION" != "build" ]; then
    echo "Uso: $0 build <glibc|musl>" >&2
    exit 1
fi

# Variáveis fornecidas pelo adm
PKG="${ADM_PKG_NAME:-gcc-pass1}"
CACHE_SRC="${ADM_CACHE_SRC:-/var/cache/adm/sources}"
BUILD_ROOT="${ADM_BUILD_ROOT:-/tmp/adm-build-toolchain-gcc-pass1-${ADM_LIBC:-unknown}}"
DESTDIR="${ADM_DESTDIR:-${BUILD_ROOT}/destdir}"

# Versão real do GCC
GCC_VER="15.2.0"
ADM_PKG_VERSION="${GCC_VER}-pass1"
export ADM_PKG_VERSION

SRC_GCC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz"
SRC_GCC="${CACHE_SRC}/gcc-${GCC_VER}.tar.xz"
SRC_GCC_DIR="${BUILD_ROOT}/gcc-${GCC_VER}"

# Dependências obrigatórias para o GCC (LFS exige MPFR, GMP, MPC empacotados no source)
SRC_GMP_URL="https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
SRC_MPFR_URL="https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz"
SRC_MPC_URL="https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"

SRC_GMP="${CACHE_SRC}/gmp-6.3.0.tar.xz"
SRC_MPFR="${CACHE_SRC}/mpfr-4.2.1.tar.xz"
SRC_MPC="${CACHE_SRC}/mpc-1.3.1.tar.gz"

log()  { printf "[%s] %s\n" "$(date +'%H:%M:%S')" "$*"; }
err()  { printf "[%s] [ERRO] %s\n" "$(date +'%H:%M:%S')" "$*" >&2; }

download() {
    mkdir -p "$CACHE_SRC"

    # GCC
    if [ ! -f "$SRC_GCC" ]; then
        log "Baixando GCC ${GCC_VER}..."
        curl -L -o "$SRC_GCC" "$SRC_GCC_URL" || wget -O "$SRC_GCC" "$SRC_GCC_URL"
    else
        log "Usando cache: $SRC_GCC"
    fi

    # GMP
    if [ ! -f "$SRC_GMP" ]; then
        log "Baixando GMP..."
        curl -L -o "$SRC_GMP" "$SRC_GMP_URL" || wget -O "$SRC_GMP" "$SRC_GMP_URL"
    else
        log "Usando cache: $SRC_GMP"
    fi

    # MPFR
    if [ ! -f "$SRC_MPFR" ]; then
        log "Baixando MPFR..."
        curl -L -o "$SRC_MPFR" "$SRC_MPFR_URL" || wget -O "$SRC_MPFR" "$SRC_MPFR_URL"
    else
        log "Usando cache: $SRC_MPFR"
    fi

    # MPC
    if [ ! -f "$SRC_MPC" ]; then
        log "Baixando MPC..."
        curl -L -o "$SRC_MPC" "$SRC_MPC_URL" || wget -O "$SRC_MPC" "$SRC_MPC_URL"
    else
        log "Usando cache: $SRC_MPC"
    fi
}

prepare() {
    rm -rf "$BUILD_ROOT"
    mkdir -p "$BUILD_ROOT" "$DESTDIR"

    log "Extraindo GCC..."
    tar -xf "$SRC_GCC" -C "$BUILD_ROOT"

    cd "$SRC_GCC_DIR"

    log "Integrando GMP, MPFR e MPC ao source do GCC..."
    tar -xf "$SRC_GMP"  -C "$SRC_GCC_DIR"
    mv gmp-* gmp

    tar -xf "$SRC_MPFR" -C "$SRC_GCC_DIR"
    mv mpfr-* mpfr

    tar -xf "$SRC_MPC"  -C "$SRC_GCC_DIR"
    mv mpc-* mpc

    mkdir -pv build
    cd build
}

build_gcc() {
    # Alvo LFS
    export LFS="${ADM_ROOTFS:?ADM_ROOTFS não definido}"
    export LFS_TGT="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"

    log "Configurando GCC ${GCC_VER} - Pass 1"
    ../configure \
        --target="${LFS_TGT}" \
        --prefix=/tools \
        --with-glibc-version=2.38 \
        --with-newlib \
        --without-headers \
        --enable-default-hash-style=gnu \
        --enable-default-pie \
        --enable-new-dtags \
        --enable-languages=c \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdc++ \
        --disable-werror

    log "Compilando GCC pass1..."
    make

    log "Instalando GCC pass1 em DESTDIR=${DESTDIR}"
    make DESTDIR="${DESTDIR}" install

    log "Compilando libgcc..."
    make -C "$SRC_GCC_DIR/build/gcc" libgcc.a

    log "Instalando libgcc..."
    make -C "$SRC_GCC_DIR/build/gcc" DESTDIR="${DESTDIR}" install-libgcc

    log "GCC Pass 1 concluído"
}

case "$ACTION" in
    build)
        download
        prepare
        build_gcc
        ;;
esac
