#!/usr/bin/env bash

# Pacote: MPFR-4.2.2
# Categoria: core
# Nome: mpfr
#
# Biblioteca de ponto flutuante de múltipla precisão usada pelo GCC.
# Este é o MPFR "final", instalado em /usr dentro do ROOTFS via DESTDIR do ADM.

PKG_NAME="mpfr"
PKG_CATEGORY="core"
PKG_VERSION="4.2.2"
PKG_DESC="MPFR ${PKG_VERSION} - multiple-precision floating-point library with exact rounding"
PKG_HOMEPAGE="https://www.mpfr.org/"

# Tarball oficial do GNU/MPFR (versão estável 4.2.2) 
PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/mpfr/mpfr-${PKG_VERSION}.tar.xz"
)

# SHA256 pode ser obtido dos mirrors LFS / sum files; usei o valor publicado
# para mpfr-4.2.2.tar.xz. 
PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "cbd736ea220bcd3d0647c0c5a4bb49bbf068d01fc6ce4787916b3b8c963d5806"
)

# Dependências: precisa que o GMP já esteja presente no ROOTFS
# (libgmp e headers) para compilar.
PKG_DEPENDS=(
    "gmp"
)

pkg_build() {
    : "${SRC_DIR:?SRC_DIR não definido}"
    : "${BUILD_DIR:?BUILD_DIR não definido}"

    echo ">>> [mpfr] SRC_DIR=${SRC_DIR}"
    echo ">>> [mpfr] BUILD_DIR=${BUILD_DIR}"

    cd "$SRC_DIR"

    # Diretório de build separado (boa prática e padrão no ADM)
    mkdir -pv "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Configuração baseada no LFS 12.4 (8.22 MPFR-4.2.2): 
    #
    #   ./configure --prefix=/usr       \
    #               --disable-static    \
    #               --enable-thread-safe\
    #               --docdir=/usr/share/doc/mpfr-4.2.2
    #
    # LFS usa também --enable-gmp-internals em alguns contextos avançados,
    # mas para uso padrão com GCC isso não é necessário.

    ../configure \
        --prefix=/usr \
        --disable-static \
        --enable-thread-safe \
        --docdir=/usr/share/doc/mpfr-${PKG_VERSION}

    # Compila biblioteca e docs HTML (como o livro sugere)
    make -j"${ADM_JOBS:-$(nproc)}"
    make html
}

pkg_install() {
    : "${BUILD_DIR:?BUILD_DIR não definido}"
    : "${DESTDIR:?DESTDIR não definido}"

    cd "$BUILD_DIR"

    # Instala biblioteca e headers dentro do DESTDIR
    make DESTDIR="$DESTDIR" install

    # Instala documentação HTML no DESTDIR
    make DESTDIR="$DESTDIR" install-html

    # Opcional: garantir que não restou lib estática mesmo se a opção mudar
    rm -f "$DESTDIR/usr/lib/libmpfr.a" || true
}
