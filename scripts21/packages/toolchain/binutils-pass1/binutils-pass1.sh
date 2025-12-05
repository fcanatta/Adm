#!/usr/bin/env bash

# Pacote: Binutils-2.45.1 - Pass 1 (cross-toolchain)
# Categoria: toolchain
# Nome: binutils-pass1
#
# Este script segue as instruções do LFS 12.4 (Binutils-2.45.1 - Pass 1),
# adaptado para o gerenciador ADM (ROOTFS + DESTDIR).
#
# Ele constrói o Binutils como ferramenta de cross-compilação, instalando em
# /tools dentro do ROOTFS do perfil atual.

PKG_NAME="binutils-pass1"
PKG_CATEGORY="toolchain"
PKG_VERSION="2.45.1"
PKG_DESC="GNU Binutils 2.45.1 - Pass 1 (cross-toolchain)"
PKG_HOMEPAGE="https://www.gnu.org/software/binutils/"
PKG_CHECKSUM_TYPE="md5"

# Fonte oficial (LFS)
PKG_SOURCE=(
    "https://sourceware.org/pub/binutils/releases/binutils-2.45.1.tar.xz"
)

# MD5 oficial de binutils-2.45.1.tar.xz (LFS r12.4) 
PKG_CHECKSUMS=(
    "ff59f8dc1431edfa54a257851bea74e7"
)

# Binutils pass1 não depende de outros pacotes do próprio ADM;
# depende apenas do ambiente host + variáveis LFS_TGT/ROOTFS corretamente setadas.
PKG_DEPENDS=()

# -----------------------------------------------------------------------------
# Função de build
# -----------------------------------------------------------------------------
pkg_build() {
    # SRC_DIR, BUILD_DIR, DESTDIR e ROOTFS são exportadas pelo adm.sh
    # antes de chamar pkg_build.

    # Checa se o alvo de cross-compilação está definido
    : "${LFS_TGT:?Variável LFS_TGT não definida. Configure o perfil cross do ADM.}"
    : "${ROOTFS:?Variável ROOTFS não definida (ADM_ROOTFS).}"

    echo ">>> [binutils-pass1] Usando LFS_TGT=${LFS_TGT}"
    echo ">>> [binutils-pass1] ROOTFS=${ROOTFS}"
    echo ">>> [binutils-pass1] BUILD_DIR=${BUILD_DIR}"
    echo ">>> [binutils-pass1] DESTDIR=${DESTDIR}"

    cd "$SRC_DIR"

    # Diretório de build separado (como recomendado pelo próprio Binutils/LFS)
    mkdir -v build
    cd build

    # Configuração do Binutils cross (equivalente ao LFS, mas usando /tools + ROOTFS)
    ../configure \
        --prefix=/tools \
        --with-sysroot="$ROOTFS" \
        --target="$LFS_TGT" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror \
        --enable-new-dtags \
        --enable-default-hash-style=gnu

    # Compila
    make
}

# -----------------------------------------------------------------------------
# Função de instalação
# -----------------------------------------------------------------------------
pkg_install() {
    # A build foi feita em $SRC_DIR/build
    cd "$SRC_DIR/build"

    # Instala no DESTDIR; o ADM depois sincroniza DESTDIR -> ROOTFS
    make DESTDIR="$DESTDIR" install
}
