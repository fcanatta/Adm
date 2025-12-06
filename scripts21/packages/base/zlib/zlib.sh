#!/usr/bin/env bash

# Pacote: Zlib-1.3.1
# Categoria: core
# Nome: zlib
#
# Biblioteca de compressão usada por vários programas (libz.so).
# Baseado no procedimento do LFS 8.6 Zlib-1.3.1. 

PKG_NAME="zlib"
PKG_CATEGORY="core"
PKG_VERSION="1.3.1"
PKG_DESC="Zlib ${PKG_VERSION} - biblioteca de compressão (libz)"
PKG_HOMEPAGE="https://zlib.net/"

# Usando o tar.xz oficial com SHA-256 documentado na página do zlib. 
PKG_SOURCE=(
    "https://zlib.net/zlib-1.3.1.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "38ef96b8dfe510d42707d9c781877914792541133e1870841463bfa73f883e32"
)

# Zlib não depende de nada além de toolchain (gcc, make, etc)
PKG_DEPENDS=()

pkg_build() {
    : "${SRC_DIR:?SRC_DIR não definido}"
    : "${BUILD_DIR:?BUILD_DIR não definido}"

    echo ">>> [zlib] SRC_DIR=${SRC_DIR}"
    echo ">>> [zlib] BUILD_DIR=${BUILD_DIR}"

    cd "$SRC_DIR"

    # Diretório de build separado (não é obrigatório, mas mantém padrão do ADM)
    mkdir -pv "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Do LFS: ./configure --prefix=/usr 
    ../configure --prefix=/usr

    # make
    make -j"${ADM_JOBS:-$(nproc)}"
}

pkg_install() {
    : "${BUILD_DIR:?BUILD_DIR não definido}"
    : "${DESTDIR:?DESTDIR não definido}"

    cd "$BUILD_DIR"

    # make install embaixo do DESTDIR (ADM depois rsync DESTDIR -> ROOTFS)
    make DESTDIR="$DESTDIR" install

    # Remove lib estática inútil, mas dentro do DESTDIR (equivalente ao rm -fv /usr/lib/libz.a do LFS) 
    rm -f "$DESTDIR/usr/lib/libz.a" || true
}
