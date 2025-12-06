#!/usr/bin/env bash

# Pacote: Binutils-2.45.1 (final)
# Categoria: core
# Nome: binutils
#
# Este é o binutils "final", instalado em /usr dentro do ROOTFS.
# Baseado em LFS 12.4 (cap. 8.21 Binutils-2.45.1). 

PKG_NAME="binutils"
PKG_CATEGORY="core"
PKG_VERSION="2.45.1"
PKG_DESC="GNU Binutils ${PKG_VERSION} - assembler, linker e ferramentas para objetos"
PKG_HOMEPAGE="https://www.gnu.org/software/binutils/"

# Fonte oficial (LFS usa o tarball de sourceware.org) 
PKG_SOURCE=(
    "https://sourceware.org/pub/binutils/releases/binutils-${PKG_VERSION}.tar.xz"
)

# MD5 oficial do LFS para binutils-2.45.1.tar.xz 
PKG_CHECKSUM_TYPE="md5"
PKG_CHECKSUMS=(
    "ff59f8dc1431edfa54a257851bea74e7"
)

# Dependências lógicas (ajuste os nomes conforme seus pacotes ADM)
PKG_DEPENDS=(
    "zlib"
)

pkg_build() {
    : "${SRC_DIR:?SRC_DIR não definido}"
    : "${BUILD_DIR:?BUILD_DIR não definido}"

    echo ">>> [binutils] SRC_DIR=${SRC_DIR}"
    echo ">>> [binutils] BUILD_DIR=${BUILD_DIR}"

    cd "$SRC_DIR"

    # Diretório de build dedicado, como recomendado pela doc do binutils/LFS 
    mkdir -pv "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Configuração final baseada em LFS 8.21 (Binutils-2.45.1) 
    ../configure \
        --prefix=/usr       \
        --sysconfdir=/etc   \
        --enable-ld=default \
        --enable-plugins    \
        --enable-shared     \
        --disable-werror    \
        --enable-64-bit-bfd \
        --enable-new-dtags  \
        --with-system-zlib  \
        --enable-default-hash-style=gnu

    # Compila. LFS usa `make tooldir=/usr` (sem DESTDIR ainda). 
    make tooldir=/usr -j"${ADM_JOBS:-$(nproc)}"
}

pkg_install() {
    : "${BUILD_DIR:?BUILD_DIR não definido}"
    : "${DESTDIR:?DESTDIR não definido}"

    cd "$BUILD_DIR"

    # Instala no DESTDIR; o ADM depois faz rsync DESTDIR -> ROOTFS
    make tooldir=/usr DESTDIR="$DESTDIR" install

    # Remove libs estáticas inúteis e doc do gprofng, como no LFS 
    rm -f \
        "$DESTDIR/usr/lib/libbfd.a" \
        "$DESTDIR/usr/lib/libctf.a" \
        "$DESTDIR/usr/lib/libctf-nobfd.a" \
        "$DESTDIR/usr/lib/libgprofng.a" \
        "$DESTDIR/usr/lib/libopcodes.a" \
        "$DESTDIR/usr/lib/libsframe.a" || true

    rm -rf "$DESTDIR/usr/share/doc/gprofng" || true
}
