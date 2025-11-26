#!/usr/bin/env bash
# Recipe: gcc-pass1
# LFS:    5.3. GCC-15.2.0 - Pass 1

PKG_NAME="gcc-pass1"
PKG_VERSION="15.2.0"
PKG_RELEASE="1"

PKG_DESC="GCC 15.2.0 - Pass 1 (cross-compiler C/C++ para LFS)"
PKG_LICENSE="GPL-3.0-or-later"
PKG_URL="https://gcc.gnu.org/"
PKG_GROUPS="cross-toolchain cross-toolchain-musl"

# Fontes principais + GMP/MPFR/MPC embutidos no source tree
PKG_SOURCES="https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz \
https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz \
https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz \
https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"

# MD5 alinhados com PKG_SOURCES (mesma ordem)
PKG_MD5S="b861b092bf1af683c46a8aa2e689a6fd \
5e77f6059679e353926131b682bb84fa \
956dc04e864001a9c22429f761f2c283 \
5c9bc658c9fd0f940e8e3e0f09530c62"

# Bind: gcc-pass1 precisa do binutils-pass1 já instalado
PKG_DEPENDS="binutils-pass1"

# Upstream fixo (para LFS cross-toolchain não é pra ficar atualizando)
pkg_upstream_version() {
  echo "$PKG_VERSION"
}

# -------------------------------------------------------------
# prepare(): embute MPFR/GMP/MPC no source tree do GCC
# -------------------------------------------------------------
pkg_prepare() {
  : "${LFS:?Variável LFS não definida}"
  : "${LFS_TGT:?Variável LFS_TGT não definida}"
  : "${ADM_SRC_CACHE:?ADM_SRC_CACHE não definido}"

  # Estamos dentro de $srcdir (gcc-15.2.0) por causa do adm.sh
  # Extrai MPFR
  tar -xf "$ADM_SRC_CACHE/mpfr-4.2.2.tar.xz"
  mv -v mpfr-4.2.2 mpfr

  # Extrai GMP
  tar -xf "$ADM_SRC_CACHE/gmp-6.3.0.tar.xz"
  mv -v gmp-6.3.0 gmp

  # Extrai MPC
  tar -xf "$ADM_SRC_CACHE/mpc-1.3.1.tar.gz"
  mv -v mpc-1.3.1 mpc

  # Ajuste de lib64 -> lib em x86_64
  case "$(uname -m)" in
    x86_64)
      sed -e '/m64=/s/lib64/lib/' \
          -i.orig gcc/config/i386/t-linux64
      ;;
  esac
}

# -------------------------------------------------------------
# build(): configura e compila o GCC cross
# -------------------------------------------------------------
pkg_build() {
  : "${LFS:?Variável LFS não definida}"
  : "${LFS_TGT:?Variável LFS_TGT não definida}"

  mkdir -v build
  cd build

  ../configure                  \
      --target="$LFS_TGT"       \
      --prefix="$LFS/tools"     \
      --with-glibc-version=2.42 \
      --with-sysroot="$LFS"     \
      --with-newlib             \
      --without-headers         \
      --enable-default-pie      \
      --enable-default-ssp      \
      --disable-nls             \
      --disable-shared          \
      --disable-multilib        \
      --disable-threads         \
      --disable-libatomic       \
      --disable-libgomp         \
      --disable-libquadmath     \
      --disable-libssp          \
      --disable-libvtv          \
      --disable-libstdcxx       \
      --enable-languages=c,c++

  make

  # Volta para o diretório raiz do source para o install()
  cd ..
}

# -------------------------------------------------------------
# install(): instala em $PKG_DESTDIR/$LFS/tools e gera limits.h
# -------------------------------------------------------------
pkg_install() {
  : "${LFS:?Variável LFS não definida}"
  : "${LFS_TGT:?Variável LFS_TGT não definida}"
  : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"

  # Entrar no diretório de build criado em pkg_build()
  cd build

  # Instala em staging: $PKG_DESTDIR + prefixo ($LFS/tools)
  make DESTDIR="$PKG_DESTDIR" install

  cd ..

  # Agora geramos o limits.h completo dentro do staging,
  # igual ao livro, mas prefixando com PKG_DESTDIR.
  local cc_bin libgcc_dir
  cc_bin="${PKG_DESTDIR}${LFS}/tools/bin/${LFS_TGT}-gcc"

  if [[ ! -x "$cc_bin" ]]; then
    echo "ERRO: compilador ${cc_bin} não encontrado após make install" >&2
    return 1
  fi

  # dirname `$LFS_TGT-gcc -print-libgcc-file-name`, com PKG_DESTDIR
  libgcc_dir="$PKG_DESTDIR$(dirname "$("$cc_bin" -print-libgcc-file-name)")"
  mkdir -p "$libgcc_dir/include"

  # Mesma concatenação de headers que o LFS faz
  cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
      "$libgcc_dir/include/limits.h"
}
