# Zstd-1.5.7 - Zstandard Utils (LFS r12.4-46, cap. 8.10)

PKG_NAME="zstd"
PKG_VERSION="1.5.7"
PKG_RELEASE="1"

PKG_GROUPS="core libs"

PKG_DESC="Zstandard: biblioteca e ferramentas de compressão de alta taxa, em tempo real"
PKG_URL="https://facebook.github.io/zstd/"
PKG_LICENSE="BSD-3-Clause"

PKG_SOURCES="https://github.com/facebook/zstd/releases/download/v${PKG_VERSION}/zstd-${PKG_VERSION}.tar.gz"
PKG_MD5S="780fc1896922b1bc52a4e90980cdda48"

PKG_DEPENDS="glibc"

###############################################################################
# 8.10.1. Installation of Zstd (adaptado para o adm)
###############################################################################

pkg_prepare() {
  # Diretório fonte: zstd-1.5.7/
  :
}

pkg_build() {
  # LFS: make prefix=/usr
  make prefix=/usr
}

pkg_check() {
  # LFS: make check
  make check

  ###########################################################################
  # CHECK EXTRA: garantir que a lib compartilhada libzstd.so foi gerada
  ###########################################################################

  # As libs ficam em lib/libzstd.so*
  if ! ls lib/libzstd.so* >/dev/null 2>&1; then
    die "FALHA: Nenhuma biblioteca compartilhada libzstd.so foi gerada (lib/libzstd.so* ausente)!"
  fi

  # Verificação mais forte: arquivo de versão específica
  if [[ ! -f "lib/libzstd.so.${PKG_VERSION}" ]]; then
    die "FALHA: lib/libzstd.so.${PKG_VERSION} não existe — build incompleto!"
  fi

  log_info "Check OK: libzstd.so foi gerada corretamente."
}

pkg_install() {
  # LFS: make prefix=/usr install
  make prefix=/usr DESTDIR="$PKG_DESTDIR" install

  # LFS: rm -v /usr/lib/libzstd.a
  rm -v "$PKG_DESTDIR/usr/lib/libzstd.a" || true
}

pkg_upstream_version() {
  adm_generic_upstream_version
}
