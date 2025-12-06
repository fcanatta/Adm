#!/usr/bin/env bash

# Pacote: GMP-6.3.0
# Categoria: core
# Nome: gmp
#
# Biblioteca de inteiros/floating-point de precisão arbitrária (libgmp, libgmpxx).
# Este é o GMP "final", instalado em /usr dentro do ROOTFS (via DESTDIR do ADM).

PKG_NAME="gmp"
PKG_CATEGORY="core"
PKG_VERSION="6.3.0"
PKG_DESC="GMP ${PKG_VERSION} - GNU Multiple Precision Arithmetic Library"
PKG_HOMEPAGE="https://gmplib.org/"

# Tarball oficial (espelhado em vários mirrors, ex: LFS, gmplib.org) 
PKG_SOURCE=(
    "https://gmplib.org/download/gmp/gmp-${PKG_VERSION}.tar.xz"
)

# SHA256 amplamente usada em mirrors de LFS para gmp-6.3.0.tar.xz 
PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"
)

# Dependências: nada além de toolchain (gcc, binutils, glibc já presentes no ROOTFS)
PKG_DEPENDS=()

pkg_build() {
    : "${SRC_DIR:?SRC_DIR não definido}"
    : "${BUILD_DIR:?BUILD_DIR não definido}"

    echo ">>> [gmp] SRC_DIR=${SRC_DIR}"
    echo ">>> [gmp] BUILD_DIR=${BUILD_DIR}"

    cd "$SRC_DIR"

    # Diretório de build separado (boa prática e combina com o ADM)
    mkdir -pv "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Configuração baseada no LFS 12.1: 
    #
    #   ./configure --prefix=/usr    \
    #               --enable-cxx     \
    #               --disable-static \
    #               --docdir=/usr/share/doc/gmp-6.3.0
    #
    # Obs: se você quiser libs genéricas (sem otimizar pro CPU local),
    # pode usar:  ABI=32 ./configure ... ou --host=none-linux-gnu para casos específicos.

    ../configure \
        --prefix=/usr \
        --enable-cxx \
        --disable-static \
        --docdir=/usr/share/doc/gmp-${PKG_VERSION}

    # Compila lib e docs HTML (como no livro)
    make -j"${ADM_JOBS:-$(nproc)}"
    make html
}

pkg_install() {
    : "${BUILD_DIR:?BUILD_DIR não definido}"
    : "${DESTDIR:?DESTDIR não definido}"

    cd "$BUILD_DIR"

    # Instala bibliotecas + headers embaixo do DESTDIR
    make DESTDIR="$DESTDIR" install

    # Instala documentação HTML embaixo do DESTDIR também
    make DESTDIR="$DESTDIR" install-html

    # Não removo .a aqui porque o LFS mantém libgmp.a/libgmpxx.a por padrão;
    # se quiser só .so, pode descomentar:
    # rm -f "$DESTDIR/usr/lib/libgmp.a" "$DESTDIR/usr/lib/libgmpxx.a" || true
}
