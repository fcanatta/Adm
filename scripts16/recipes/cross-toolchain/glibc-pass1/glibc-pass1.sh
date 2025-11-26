#!/usr/bin/env bash
# Glibc-2.42 (cross-toolchain)
# LFS r12.4-46 - Capítulo 5.5
# https://www.linuxfromscratch.org/lfs/view/development/chapter05/glibc.html

PKG_NAME="glibc-pass1"
PKG_VERSION="2.42"
PKG_RELEASE="1"

PKG_DESC="Glibc ${PKG_VERSION} - libc principal do sistema (fase cross-toolchain do LFS)"
PKG_LICENSE="LGPL-2.1-or-later"
PKG_URL="https://www.gnu.org/software/libc/"
PKG_GROUPS="cross-toolchain"

# Ordem no LFS:
#   Binutils-pass1 -> GCC-pass1 -> Linux-headers -> Glibc
PKG_DEPENDS="binutils-pass1 gcc-pass1 linux-headers"

# Usando os mesmos mirrors do LFS (pacotes 12.4)
PKG_SOURCES="https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4/glibc-${PKG_VERSION}.tar.xz \
https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4/glibc-${PKG_VERSION}-fhs-1.patch"

# Mesma ordem que em PKG_SOURCES
PKG_MD5S="23c6f5a27932b435cae94e087cb8b1f5 \
f75cca16a38da6caa7d52151f7136895"

# Cross-toolchain não deve ser atualizado automaticamente
pkg_upstream_version() {
  printf '%s\n' "${PKG_VERSION}"
}

# -------------------------------------------------------------
# prepare(): checa ambiente (LFS/LFS_TGT)
# -------------------------------------------------------------
pkg_prepare() {
  : "${LFS:?Variável LFS não definida. Exporte LFS antes de construir $PKG_NAME}"
  : "${LFS_TGT:?Variável LFS_TGT não definida. Exporte LFS_TGT antes de construir $PKG_NAME}"
  : "${ADM_SRC_CACHE:?ADM_SRC_CACHE não definido}"
}

# -------------------------------------------------------------
# build(): aplica o patch FHS, cria build dir, configura e compila
# -------------------------------------------------------------
pkg_build() {
  : "${LFS:?Variável LFS não definida}"
  : "${LFS_TGT:?Variável LFS_TGT não definida}"
  : "${ADM_SRC_CACHE:?ADM_SRC_CACHE não definido}"

  # Estamos em $srcdir = glibc-2.42 (o adm já fez cd pra cá)

  # Patch FHS (var/db -> locais FHS-compliant), como no livro
  patch -Np1 -i "${ADM_SRC_CACHE}/glibc-${PKG_VERSION}-fhs-1.patch"

  # Diretório de build separado
  mkdir -v build
  cd       build

  # Garante que ldconfig e sln vão para /usr/sbin
  echo "rootsbindir=/usr/sbin" > configparms

  # Configure exatamente como no LFS
  ../configure                             \
        --prefix=/usr                      \
        --host="$LFS_TGT"                  \
        --build="$(../scripts/config.guess)" \
        --disable-nscd                     \
        libc_cv_slibdir=/usr/lib           \
        --enable-kernel=5.4

  # Compila (se der problema com paralelismo, rode com -j1 fora do adm)
  make

  # Voltamos um nível para o install() poder fazer cd build de novo
  cd ..
}

# -------------------------------------------------------------
# check(): o LFS faz sanity check MANUAL depois da instalação.
#          Aqui deixamos vazio; você roda os comandos do livro
#          depois de 'adm install glibc'.
# -------------------------------------------------------------
pkg_check() {
  :
}

# -------------------------------------------------------------
# install():
#   - make DESTDIR=$LFS install
#     (adaptado para o staging do adm: $PKG_DESTDIR$LFS)
#   - cria os symlinks LSB em $LFS/lib* (via staging)
#   - ajusta o ldd para não ter /usr hardcoded
# -------------------------------------------------------------
pkg_install() {
  : "${LFS:?Variável LFS não definida}"
  : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"

  # Entrar no diretório de build
  cd build

  # LFS manda: make DESTDIR=$LFS install
  # Aqui: instalamos em staging -> ${PKG_DESTDIR}${LFS}
  make DESTDIR="${PKG_DESTDIR}${LFS}" install

  cd ..

  # Symlinks para compatibilidade LSB (como no livro, mas dentro do staging)
  case "$(uname -m)" in
    i?86)
      mkdir -p "${PKG_DESTDIR}${LFS}/lib"
      ln -sfv ld-linux.so.2 \
        "${PKG_DESTDIR}${LFS}/lib/ld-lsb.so.3"
      ;;
    x86_64)
      mkdir -p "${PKG_DESTDIR}${LFS}/lib64"
      # No livro:
      #   ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64
      #   ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64/ld-lsb-x86-64.so.3
      ln -sfv ../lib/ld-linux-x86-64.so.2 \
        "${PKG_DESTDIR}${LFS}/lib64/ld-linux-x86-64.so.2"
      ln -sfv ../lib/ld-linux-x86-64.so.2 \
        "${PKG_DESTDIR}${LFS}/lib64/ld-lsb-x86-64.so.3"
      ;;
  esac

  # Ajuste do ldd (mesmo sed do livro, mas no staging)
  if [[ -f "${PKG_DESTDIR}${LFS}/usr/bin/ldd" ]]; then
    sed '/RTLDLIST=/s@/usr@@g' -i "${PKG_DESTDIR}${LFS}/usr/bin/ldd"
  fi
}
