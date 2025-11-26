# Zstd-1.5.7 - Zstandard Utils (LFS r12.4-46, cap. 8.10)

PKG_NAME="zstd"
PKG_VERSION="1.5.7"
PKG_RELEASE="1"

PKG_GROUPS="core libs"

PKG_DESC="Zstandard: biblioteca e ferramentas de compressão de alta taxa, em tempo real"
PKG_URL="https://facebook.github.io/zstd/"
PKG_LICENSE="BSD-3-Clause"

# LFS 12.4 (development / r12.4-xx): 3
#   Home page: https://facebook.github.io/zstd/
#   Download:  https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
#   MD5:       780fc1896922b1bc52a4e90980cdda48
PKG_SOURCES="https://github.com/facebook/zstd/releases/download/v${PKG_VERSION}/zstd-${PKG_VERSION}.tar.gz"
PKG_MD5S="780fc1896922b1bc52a4e90980cdda48"

PKG_DEPENDS="glibc"

###############################################################################
# 8.10.1. Installation of Zstd (adaptado para o adm)
###############################################################################

pkg_prepare() {
  # Diretório fonte: zstd-1.5.7/
  # Build padrão é direto com make, sem ./configure pro caso LFS.
  :
}

pkg_build() {
  # LFS: make prefix=/usr
  make prefix=/usr
}

pkg_check() {
  # LFS: make check (e ignorar 'failed' que não sejam 'FAIL' no output)
  make check
}

pkg_install() {
  # LFS: make prefix=/usr install
  # Aqui fazemos staging com DESTDIR.
  make prefix=/usr DESTDIR="$PKG_DESTDIR" install

  # LFS: rm -v /usr/lib/libzstd.a
  rm -v "$PKG_DESTDIR/usr/lib/libzstd.a" || true
}

# Usa helper genérico do adm para descobrir última versão em
# https://github.com/facebook/zstd/releases (zstd-*.tar.*).
pkg_upstream_version() {
  adm_generic_upstream_version
}
