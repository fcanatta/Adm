#!/usr/bin/env bash
# Bash-5.2.32 — LFS Chapter 6.4 (Temporary Tools)
# https://www.linuxfromscratch.org/lfs/view/development/chapter06/bash.html

PKG_NAME="bash-pass1"
PKG_VERSION="5.2.32"
PKG_RELEASE="1"

PKG_DESC="Bash ${PKG_VERSION} - shell Bourne-Again (ferramenta temporária cross para LFS)"
PKG_LICENSE="GPL-3.0-or-later"
PKG_URL="https://www.gnu.org/software/bash/"
PKG_GROUPS="cross-toolchain"

# Ordem de dependências no capítulo 6:
#   m4 -> ncurses -> bash
# Mais o toolchain/glibc básico já pronto
PKG_DEPENDS="binutils-pass1 gcc-pass1 linux-headers glibc-pass1 gcc-libstdc++ m4-pass1 ncurses-pass1"

# Fonte e MD5 conforme lista de pacotes do LFS 12.2/12.4 dev
# Download: https://ftp.gnu.org/gnu/bash/bash-5.2.32.tar.gz
# MD5 sum: f204835b2e06c06e37b5ad776ff907f4
PKG_SOURCES="https://ftp.gnu.org/gnu/bash/bash-${PKG_VERSION}.tar.gz"
PKG_MD5SUM="f204835b2e06c06e37b5ad776ff907f4"

# Para ferramentas temporárias, não faz sentido upgrade automático
pkg_upstream_version() {
  printf '%s\n' "${PKG_VERSION}"
}

# -------------------------------------------------------------
# prepare(): só valida ambiente
# -------------------------------------------------------------
pkg_prepare() {
  : "${LFS:?Variável LFS não definida. Exporte LFS=/mnt/lfs (por exemplo)}"
  : "${LFS_TGT:?Variável LFS_TGT não definida. Ex: x86_64-lfs-linux-gnu}"
}

# -------------------------------------------------------------
# build():
#   ./configure --prefix=/usr                      \
#               --build=$(sh support/config.guess) \
#               --host=$LFS_TGT                    \
#               --without-bash-malloc              \
#               bash_cv_strtold_broken=no
#   make
# -------------------------------------------------------------
pkg_build() {
  : "${LFS:?Variável LFS não definida}"
  : "${LFS_TGT:?Variável LFS_TGT não definida}"

  # Estamos em $srcdir = bash-5.2.32 (adm já deu cd pra cá)
  bash_cv_strtold_broken=no \
  ./configure \
      --prefix=/usr                      \
      --build="$(sh support/config.guess)" \
      --host="$LFS_TGT"                  \
      --without-bash-malloc

  make
}

# -------------------------------------------------------------
# check(): o livro não roda testes para Bash em Chapter 6
# -------------------------------------------------------------
pkg_check() {
  :
}

# -------------------------------------------------------------
# install():
#   make DESTDIR=$LFS install
# adaptado para o adm:
#   DESTDIR = ${PKG_DESTDIR}${LFS}
# -------------------------------------------------------------
pkg_install() {
  : "${LFS:?Variável LFS não definida}"
  : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"

  make DESTDIR="${PKG_DESTDIR}${LFS}" install
}
