#!/usr/bin/env bash
# Linux-${PKG_VERSION} API Headers (cross-toolchain)
# LFS r12.4-46 - Capítulo 5.4
# https://www.linuxfromscratch.org/lfs/view/development/chapter05/linux-headers.html

PKG_NAME="linux-headers"
PKG_VERSION="6.17.8"
PKG_RELEASE="1"

PKG_DESC="Linux ${PKG_VERSION} API Headers para o toolchain do LFS"
PKG_LICENSE="GPL-2.0-only"
PKG_URL="https://www.kernel.org/"
PKG_GROUPS="cross-toolchain cross-toolchain-musl"

# Ordem no livro: binutils-pass1 -> gcc-pass1 -> linux-headers -> glibc
# Tecnicamente os headers não precisam de gcc/binutils, mas manter a ordem ajuda o topo sort.
PKG_DEPENDS="binutils-pass1 gcc-pass1"

# Pacote do kernel usado no LFS:
# Download e MD5 conforme página de pacotes do LFS:
#   https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.17.8.tar.xz
#   MD5 sum: 74c34fafb5914d05447863cdc304ab55
PKG_SOURCES="https://www.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
PKG_MD5SUM="74c34fafb5914d05447863cdc304ab55"

# Para o toolchain cross, não queremos upgrades automáticos
pkg_upstream_version() {
  printf '%s\n' "${PKG_VERSION}"
}

# -------------------------------------------------------------
# prepare(): apenas valida o ambiente
# -------------------------------------------------------------
pkg_prepare() {
  : "${LFS:?Variável LFS não definida. Exporte LFS antes de construir $PKG_NAME}"
}

# -------------------------------------------------------------
# build(): segue exatamente o livro:
#   make mrproper
#   make headers
#   find usr/include -type f ! -name '*.h' -delete
# -------------------------------------------------------------
pkg_build() {
  : "${LFS:?Variável LFS não definida. Exporte LFS antes de construir $PKG_NAME}"

  # Estamos em $srcdir = linux-6.17.8 (adm já fez cd pra cá)

  # Limpa qualquer sujeira no source
  make mrproper

  # Gera headers "user-visible" em usr/include
  make headers

  # Remove arquivos que não sejam .h dentro de usr/include
  find usr/include -type f ! -name '*.h' -delete
}

# -------------------------------------------------------------
# check(): livro não manda rodar testes aqui
# -------------------------------------------------------------
pkg_check() {
  :
}

# -------------------------------------------------------------
# install(): cp -rv usr/include $LFS/usr
# adaptado para PKG_DESTDIR do adm:
#   destino final => ${LFS}/usr/include/...
#   staging       => ${PKG_DESTDIR}${LFS}/usr/include/...
# -------------------------------------------------------------
pkg_install() {
  : "${LFS:?Variável LFS não definida. Exporte LFS antes de construir $PKG_NAME}"
  : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"

  # Garante que o destino exista dentro do staging
  mkdir -p "${PKG_DESTDIR}${LFS}/usr"

  # Copia os headers para o prefixo do LFS dentro do staging
  cp -rv usr/include "${PKG_DESTDIR}${LFS}/usr"
}
