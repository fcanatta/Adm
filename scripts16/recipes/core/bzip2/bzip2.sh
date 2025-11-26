# bzip2-1.0.8 - Compactador bzip2 (LFS r12.4-46, cap. 8.7)

PKG_NAME="bzip2"
PKG_VERSION="1.0.8"
PKG_RELEASE="1"

PKG_GROUPS="core libs"

PKG_DESC="Programas e biblioteca para compressão bzip2"
PKG_URL="https://sourceware.org/bzip2/"
PKG_LICENSE="BSD-like"

PKG_SOURCES="\
https://www.sourceware.org/pub/bzip2/bzip2-${PKG_VERSION}.tar.gz \
https://www.linuxfromscratch.org/patches/lfs/12.4/bzip2-1.0.8-install_docs-1.patch"

PKG_MD5S="\
67e051268d0c475ea773822f7500d0e5 \
6a5ac7e89b791aae556de0f745916f7f"

PKG_DEPENDS="glibc"

###############################################################################
# PREPARE
###############################################################################
pkg_prepare() {

  patch -Np1 -i "$ADM_SRC_CACHE/bzip2-1.0.8-install_docs-1.patch"

  sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
  sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile

  make -f Makefile-libbz2_so
  make clean
}

###############################################################################
# BUILD
###############################################################################
pkg_build() {
  make
}

###############################################################################
# CHECK — garantia de que libbz2.so.* foi gerada
###############################################################################
pkg_check() {

  # O patch faz o shared ser construído em Makefile-libbz2_so
  # Os arquivos esperados normalmente são:
  #   libbz2.so.${PKG_VERSION}
  #   libbz2.so.1.0
  #   libbz2.so
  #
  # Vamos verificar se pelo menos **um** libbz2.so.* foi gerado.

  if ! ls libbz2.so* >/dev/null 2>&1; then
      die "FALHA: Nenhuma biblioteca compartilhada libbz2.so foi gerada!"
  fi

  # Verificação mais forte: garantir que o .so principal existe
  if [[ ! -f "libbz2.so.${PKG_VERSION}" ]]; then
      die "FALHA: libbz2.so.${PKG_VERSION} não existe — build incompleto!"
  fi

  log_info "Check OK: libbz2.so foi gerado corretamente."
}

###############################################################################
# INSTALL
###############################################################################
pkg_install() {

  make PREFIX=/usr DESTDIR="$PKG_DESTDIR" install

  install -d "$PKG_DESTDIR/usr/lib"
  cp -av libbz2.so.* "$PKG_DESTDIR/usr/lib/"
  ln -sfv "libbz2.so.${PKG_VERSION}" "$PKG_DESTDIR/usr/lib/libbz2.so"

  install -d "$PKG_DESTDIR/usr/bin"
  cp -v bzip2-shared "$PKG_DESTDIR/usr/bin/bzip2"

  for i in bzcat bunzip2; do
    ln -sfv bzip2 "$PKG_DESTDIR/usr/bin/$i"
  done

  rm -fv "$PKG_DESTDIR/usr/lib/libbz2.a" || true
}

###############################################################################
# UPSTREAM VERSION
###############################################################################
pkg_upstream_version() {
  adm_generic_upstream_version
}
