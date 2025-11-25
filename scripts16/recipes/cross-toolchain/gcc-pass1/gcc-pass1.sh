#!/bin/bash

PKG_NAME="gcc-pass1"
PKG_VERSION="15.2.0"
PKG_RELEASE="1"

PKG_DESC="GCC (Passo 1 do Toolchain Temporário) – LFS r12.4.46"
PKG_URL="https://gcc.gnu.org/"
PKG_LICENSE="GPL-3.0-or-later"
PKG_GROUPS="cross-toolchain cross-toolchain-musl"

# -------------------------------------------------------------
# Fontes oficiais (GCC + MPFR + GMP + MPC)
# -------------------------------------------------------------
PKG_SOURCES="
https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz
https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz
https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz
https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz
"

# MD5 conforme LFS-12.4.46 (tabela Chapter 3 - All Packages)
PKG_MD5S="
b0d3ca173cfc24ce9d376a7fbb53bfa6
ae3212a5f9e3c870e0f5cb1327344a79
5e8b7e9b98f6053b457769278ade41b6
b8be66396caae41e8b9c38c663937d3c
"

# SHA256 (opcional – pode deixar vazio caso não queira exigir SHA)
PKG_SHA256S=""
# Exemplo se quiser SHA:
# PKG_SHA256S="sha1 sha2 sha3 sha4"


# =====================================================================
# PREPARE – Ajustes iniciais
# =====================================================================
pkg_prepare() {
    log_info "Aplicando configuração inicial do GCC Pass 1"

    # gcc source tree é extraído como gcc-15.2.0/
    cd "$PKG_SRCEXTRACT"

    # LFS exige incorporar MPFR/GMP/MPC dentro do tree do GCC
    log_info "Incorporando MPFR, GMP e MPC no tree do GCC"
    tar -xf "$ADM_SRC_CACHE/mpfr-4.2.1.tar.xz"
    mv -v mpfr-4.2.1 mpfr

    tar -xf "$ADM_SRC_CACHE/gmp-6.3.0.tar.xz"
    mv -v gmp-6.3.0 gmp

    tar -xf "$ADM_SRC_CACHE/mpc-1.3.1.tar.gz"
    mv -v mpc-1.3.1 mpc

    # Ajuste recomendado pelo LFS
    sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
}

# =====================================================================
# BUILD – Construção do GCC Pass 1
# =====================================================================
pkg_build() {
    log_info "Construindo GCC-Pass1"

    cd "$PKG_SRCEXTRACT"

    mkdir -pv build
    cd build

    ../configure \
        --target="$LFS_TGT" \
        --prefix="/usr/src/cross-toolchain" \
        --with-glibc-version=2.42 \
        --with-sysroot="$LFS" \
        --with-newlib \
        --without-headers \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-decimal-float \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdc++-v3

    make
}

# =====================================================================
# INSTALL – Instala copia somente os binários do CROSS TOOLCHAIN
# =====================================================================
pkg_install() {
    log_info "Instalando GCC-Pass1 no DESTDIR"

    cd "$PKG_SRCEXTRACT/build"

    make DESTDIR="$PKG_DESTDIR" install

    # LFS adiciona um link simbólico para cc
    ln -sv gcc "$PKG_DESTDIR/usr/src/cross-toolchain/bin/cc"
}

# =====================================================================
# UPSTREAM VERSION (opcional)
# =====================================================================
pkg_upstream_version() {
  # Descobre a versão mais recente de GCC no ftp oficial (para upgrade)
  local url="https://ftp.gnu.org/gnu/gcc/"
  local latest=""

  if command -v curl >/dev/null 2>&1; then
    latest="$(
      curl -fsSL "$url" \
        | sed -n 's/.*gcc-\([0-9][0-9.]*\)\/.*/\1/p' \
        | sort -V \
        | tail -n1
    )"
  fi

  if [[ -n "$latest" ]]; then
    printf '%s\n' "$latest"
  else
    printf '%s\n' "$PKG_VERSION"
  fi
}
