#!/usr/bin/env bash
# M4-1.4.20 (Capítulo 6 – Ferramentas temporárias cross)
# LFS r12.4-46 - 6.2. M4-1.4.20
# https://www.linuxfromscratch.org/lfs/view/12.4/chapter06/m4.html

PKG_NAME="m4-pass1"
PKG_VERSION="1.4.20"
PKG_RELEASE="1"

PKG_DESC="M4 ${PKG_VERSION} - processador de macros (ferramenta temporária cross para LFS)"
PKG_LICENSE="GPL-3.0-or-later"
PKG_URL="https://www.gnu.org/software/m4/"
PKG_GROUPS="cross-toolchain"

# Para compilar M4 em Chapter 6 precisamos do toolchain cross pronto
# (binutils-pass1, gcc-pass1) e da glibc/headers já instalados em $LFS.
PKG_DEPENDS="binutils-pass1 gcc-pass1 linux-headers glibc-pass1 gcc-libstdc++"

# Fonte e MD5 conforme a lista de pacotes do LFS 12.4
# Download: https://ftp.gnu.org/gnu/m4/m4-1.4.20.tar.xz
# MD5 sum: 6eb2ebed5b24e74b6e890919331d2132
PKG_SOURCES="https://ftp.gnu.org/gnu/m4/m4-${PKG_VERSION}.tar.xz"
PKG_MD5SUM="6eb2ebed5b24e74b6e890919331d2132"

# Para ferramentas temporárias/cross não queremos upgrades automáticos
pkg_upstream_version() {
  printf '%s\n' "${PKG_VERSION}"
}

# -------------------------------------------------------------
# prepare(): checa ambiente
# -------------------------------------------------------------
pkg_prepare() {
  : "${LFS:?Variável LFS não definida. Exporte LFS=/mnt/lfs (por exemplo)}"
  : "${LFS_TGT:?Variável LFS_TGT não definida. Ex: x86_64-lfs-linux-gnu}"
}

# -------------------------------------------------------------
# build():
#   ./configure --prefix=/usr --host=$LFS_TGT --build=$(build-aux/config.guess)
#   make
# -------------------------------------------------------------
pkg_build() {
  : "${LFS:?Variável LFS não definida}"
  : "${LFS_TGT:?Variável LFS_TGT não definida}"

  # Estamos em $srcdir = m4-1.4.20 (o adm já fez cd pra cá)
  ./configure --prefix=/usr   \
              --host="$LFS_TGT" \
              --build="$(build-aux/config.guess)"

  make
}

# -------------------------------------------------------------
# check(): o livro não roda testes para M4 em Chapter 6
# -------------------------------------------------------------
pkg_check() {
  :
}

# -------------------------------------------------------------
# install():
#   make DESTDIR=$LFS install
#   Adaptado para o esquema do adm:
#     DESTDIR = ${PKG_DESTDIR}${LFS}
#
#   Resultado final:
#     ${PKG_DESTDIR}${LFS}/usr/bin/m4
#     ${PKG_DESTDIR}${LFS}/usr/share/... etc.
# -------------------------------------------------------------
pkg_install() {
  : "${LFS:?Variável LFS não definida}"
  : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"

  make DESTDIR="${PKG_DESTDIR}${LFS}" install
}
