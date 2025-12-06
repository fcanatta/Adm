#!/usr/bin/env bash

# Pacote: isl-0.27
# Categoria: core
# Nome: isl
#
# ISL (Integer Set Library) é usada pelo GCC para otimizações (Graphite, etc).
# Este é o isl "final", instalado em /usr dentro do ROOTFS via DESTDIR do ADM.

PKG_NAME="isl"
PKG_CATEGORY="core"
PKG_VERSION="0.27"
PKG_DESC="isl ${PKG_VERSION} - Integer Set Library usada por GCC/Clang para otimizações"
PKG_HOMEPAGE="https://libisl.sourceforge.io/"

# Tarball oficial do isl-0.27 (espelhado em vários mirrors, ex: sourceforge). 
PKG_SOURCE=(
    "https://gcc.gnu.org/pub/gcc/infrastructure/isl-${PKG_VERSION}.tar.bz2"
)

# SHA256 amplamente usada em distros para isl-0.27.tar.bz2
PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "9a7670e4c8a19a301132812eb65bfcaf187b470b236d005391d8ac7af2f259c0"
)

# Dependências: precisa de GMP (isl usa libgmp para inteiros grandes)
PKG_DEPENDS=(
    "gmp"
)

pkg_build() {
    : "${SRC_DIR:?SRC_DIR não definido}"
    : "${BUILD_DIR:?BUILD_DIR não definido}"

    echo ">>> [isl] SRC_DIR=${SRC_DIR}"
    echo ">>> [isl] BUILD_DIR=${BUILD_DIR}"

    cd "$SRC_DIR"

    # Diretório de build separado (boa prática e padrão no ADM)
    mkdir -pv "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Configuração típica (como em BLFS / toolchains modernos):
    #
    #   ./configure --prefix=/usr       \
    #               --disable-static    \
    #               --with-pic
    #
    # --with-gmp-prefix normalmente não é necessário se GMP está em /usr.
    ../configure \
        --prefix=/usr \
        --disable-static \
        --with-pic

    # Compila
    make -j"${ADM_JOBS:-$(nproc)}"

    # Opcional: tests
    # make check
}

pkg_install() {
    : "${BUILD_DIR:?BUILD_DIR não definido}"
    : "${DESTDIR:?DESTDIR não definido}"

    cd "$BUILD_DIR"

    # Instala embaixo do DESTDIR; o ADM sincroniza depois com o ROOTFS
    make DESTDIR="$DESTDIR" install

    # Segurança extra: garante que não restou lib estática se o configure mudar um dia
    rm -f "$DESTDIR/usr/lib/libisl.a" || true
}
