#!/usr/bin/env bash
# Ncurses-6.5 — LFS Chapter 6.3 (Temporary Tools)
# LFS r12.4-46
# https://www.linuxfromscratch.org/lfs/view/12.4/chapter06/ncurses.html

PKG_NAME="ncurses-cross"
PKG_VERSION="6.5"
PKG_RELEASE="1"

PKG_DESC="Ncurses ${PKG_VERSION} — biblioteca de terminal (ferramenta temporária cross do LFS)"
PKG_LICENSE="MIT"
PKG_URL="https://invisible-island.net/ncurses/"
PKG_GROUPS="cross-toolchain"

# Dependências: precisa do basic toolchain e do m4
PKG_DEPENDS="binutils-pass1 gcc-pass1 linux-headers glibc-cross gcc-libstdc++ m4-cross"

# Fonte e MD5 oficial listado na página do LFS packages
PKG_SOURCES="https://ftp.gnu.org/gnu/ncurses/ncurses-${PKG_VERSION}.tar.gz"
PKG_MD5SUM="98e2b2a6cc96540e12817fddf6f07436"

# Não atualizar automaticamente ferramentas temporárias
pkg_upstream_version() {
  echo "$PKG_VERSION"
}

# -------------------------------------------------------------
# prepare()
# -------------------------------------------------------------
pkg_prepare() {
  : "${LFS:?Erro: export LFS=/mnt/lfs}"
  : "${LFS_TGT:?Erro: export LFS_TGT=<triplet>}"

  # O livro manda desabilitar tic nativo — removemos symlinks antigos
  sed -i s/mawk// configure
}

# -------------------------------------------------------------
# build()
# -------------------------------------------------------------
pkg_build() {
  ./configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build="$(./config.guess)" \
      --mandir=/usr/share/man \
      --with-manpage-format=normal \
      --with-shared \
      --without-debug \
      --without-ada \
      --disable-stripping

  make

  # Criar versão estática especial para programas do capítulo 6
  make -C include
  make -C progs tic
}

# -------------------------------------------------------------
# check(): sem testes para ferramentas temporárias
# -------------------------------------------------------------
pkg_check() {
  :
}

# -------------------------------------------------------------
# install()
# -------------------------------------------------------------
pkg_install() {
  : "${PKG_DESTDIR:?Erro: PKG_DESTDIR não definido}"
  : "${LFS:?Erro: LFS não definido}"

  # Instalar tudo dentro do staging dirigido ao LFS
  make DESTDIR="${PKG_DESTDIR}${LFS}" install

  # Instalar tic estático (como no livro LFS)
  install -vm755 progs/tic "${PKG_DESTDIR}${LFS}/usr/bin"
}
