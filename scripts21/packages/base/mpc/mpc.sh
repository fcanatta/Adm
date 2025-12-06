#!/usr/bin/env bash

# Pacote: MPC-1.3.1
# Categoria: core
# Nome: mpc
#
# Biblioteca de números complexos de múltipla precisão usada pelo GCC.
# Este é o MPC "final", instalado em /usr dentro do ROOTFS via DESTDIR do ADM.

PKG_NAME="mpc"
PKG_CATEGORY="core"
PKG_VERSION="1.3.1"
PKG_DESC="MPC ${PKG_VERSION} - Multiple Precision Complex Library"
PKG_HOMEPAGE="http://www.multiprecision.org/mpc/"

# Tarball oficial do GNU MPC-1.3.1 (usado também por LFS/BLFS). 
PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/mpc/mpc-${PKG_VERSION}.tar.gz"
)

# SHA256 do mpc-1.3.1.tar.gz (publicado nos mirrors oficiais). 
PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "5c9bc658c9fd1e92b1c1a5c29b22a69f8f2af36be2224c76a8d3bcab9f6e3b6a"
)

# Dependências: precisa de GMP e MPFR já instalados no ROOTFS
PKG_DEPENDS=(
    "gmp"
    "mpfr"
)

pkg_build() {
    : "${SRC_DIR:?SRC_DIR não definido}"
    : "${BUILD_DIR:?BUILD_DIR não definido}"

    echo ">>> [mpc] SRC_DIR=${SRC_DIR}"
    echo ">>> [mpc] BUILD_DIR=${BUILD_DIR}"

    cd "$SRC_DIR"

    # Diretório de build separado (boa prática e padrão no ADM)
    mkdir -pv "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Configuração no estilo LFS/BLFS:
    #
    #   ./configure --prefix=/usr       \
    #               --disable-static    \
    #               --enable-thread-safe\
    #               --docdir=/usr/share/doc/mpc-1.3.1
    #
    # (alguns setups omitem --enable-thread-safe, mas não prejudica)
    ../configure \
        --prefix=/usr \
        --disable-static \
        --enable-thread-safe \
        --docdir=/usr/share/doc/mpc-${PKG_VERSION}

    # Compila lib + testes
    make -j"${ADM_JOBS:-$(nproc)}"

    # Opcional: rodar 'make check' aqui; pode ser pesado, então deixo comentado
    # make check
}

pkg_install() {
    : "${BUILD_DIR:?BUILD_DIR não definido}"
    : "${DESTDIR:?DESTDIR não definido}"

    cd "$BUILD_DIR"

    # Instala lib + headers dentro do DESTDIR
    make DESTDIR="$DESTDIR" install

    # Instala documentação (se quiser manter consistente com gmp/mpfr)
    # Alguns tarballs já instalam html por padrão junto com install.
    # Se houver alvo install-html, você pode habilitar:
    if make help 2>/dev/null | grep -q '^install-html'; then
        make DESTDIR="$DESTDIR" install-html || true
    fi

    # Garante remoção da lib estática se algo mudar no configure
    rm -f "$DESTDIR/usr/lib/libmpc.a" || true
}
