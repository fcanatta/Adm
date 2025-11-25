#!/bin/bash

# Binutils-2.45.1 - Pass 1 (Cross-toolchain)
# LFS 12.4 - Capítulo 5.2 

PKG_NAME="binutils-pass1"
PKG_VERSION="2.45.1"
PKG_RELEASE="1"

PKG_DESC="Binutils 2.45.1 (Passo 1 do toolchain cruzado LFS)"
PKG_URL="https://www.gnu.org/software/binutils/"
PKG_LICENSE="GPL-3.0-or-later"
PKG_GROUPS="cross-toolchain cross-toolchain-musl"

# Fonte oficial conforme capítulo 3.2 (All Packages) 
PKG_SOURCES="https://sourceware.org/pub/binutils/releases/binutils-2.45.1.tar.xz"

# MD5 oficial do livro (Binutils 2.45.1) 
PKG_MD5S="ff59f8dc1431edfa54a257851bea74e7"

# SHA256 opcional (não fornecido no LFS; deixe vazio ou preencha se quiser)
PKG_SHA256S=""

# Pass 1 é sempre o primeiro do cross-toolchain, então sem dependências explícitas
PKG_DEPENDS=""

pkg_build() {
  log_info "Construindo Binutils Pass 1"

  # Já estamos dentro do diretório de fonte extraído (binutils-2.45.1/)
  # O LFS manda criar um diretório separado de build: 
  mkdir -v build
  cd build

  # Raiz do toolchain (onde 'make install' vai instalar binutils)
  local cross_root="${ADM_CROSS_ROOT:-/usr/src/cross-toolchain}"

  # Sysroot (equivalente ao $LFS do livro)
  local sysroot="${ADM_CROSS_SYSROOT:-${LFS:-/mnt/lfs}}"

  # Triplet alvo (equivalente a $LFS_TGT, ex: x86_64-lfs-linux-gnu)
  local tgt="${ADM_CROSS_TARGET:-${LFS_TGT:-}}"
  if [[ -z "$tgt" ]]; then
    die "Defina ADM_CROSS_TARGET ou LFS_TGT (ex: x86_64-lfs-linux-gnu) antes de construir binutils-pass1."
  fi

  log_info "Usando cross_root=$cross_root sysroot=$sysroot target=$tgt"

  # Configure conforme LFS 5.2, adaptado para prefix=/usr/src/cross-toolchain 
  ../configure \
    --prefix="$cross_root"      \
    --with-sysroot="$sysroot"   \
    --target="$tgt"             \
    --disable-nls               \
    --enable-gprofng=no         \
    --disable-werror            \
    --enable-new-dtags          \
    --enable-default-hash-style=gnu

  # Compilar
  make
}

pkg_install() {
  log_info "Instalando Binutils Pass 1 em DESTDIR=${PKG_DESTDIR}"

  # Entrar no diretório de build criado em pkg_build()
  cd build

  # Instalação no DESTDIR do adm; o prefix usado no configure já aponta
  # para /usr/src/cross-toolchain dentro desse DESTDIR.
  make DESTDIR="$PKG_DESTDIR" install
}

pkg_upstream_version() {
  # Descobre a versão mais nova binutils-X.Y[.Z] disponível em sourceware.org
  # Se der problema de rede ou parsing, volta para PKG_VERSION.
  local url="https://sourceware.org/pub/binutils/releases/"
  local latest=""

  if command -v curl >/dev/null 2>&1; then
    latest="$(
      curl -fsSL "$url" \
        | sed -n 's/.*binutils-\([0-9][0-9.]*\)\.tar\.xz.*/\1/p' \
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
