# Lz4-1.10.0 - LZ4 Utils (LFS r12.4-46, cap. 8.9)

PKG_NAME="lz4"
PKG_VERSION="1.10.0"
PKG_RELEASE="1"

PKG_GROUPS="core libs"

PKG_DESC="LZ4: biblioteca e ferramentas de compressão ultrarrápida"
PKG_URL="https://lz4.org/"
PKG_LICENSE="BSD-2-Clause"

# LFS 12.4 packages: 1
#   Home page: https://lz4.org/
#   Download:  https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz
#   MD5:       dead9f5f1966d9ae56e1e32761e4e675
PKG_SOURCES="https://github.com/lz4/lz4/releases/download/v${PKG_VERSION}/lz4-${PKG_VERSION}.tar.gz"
PKG_MD5S="dead9f5f1966d9ae56e1e32761e4e675"

PKG_DEPENDS="glibc"

###############################################################################
# 8.9.1. Installation of Lz4 (adaptado para o adm)
###############################################################################

pkg_prepare() {
  # Diretório fonte: lz4-1.10.0/
  # Sem patches/configure especiais para LFS: build direto com make.
  :
}

pkg_build() {
  # LFS: make BUILD_STATIC=no PREFIX=/usr
  make BUILD_STATIC=no PREFIX=/usr
}

pkg_check() {
  # LFS: make -j1 check
  make -j1 check
}

pkg_install() {
  # LFS: make BUILD_STATIC=no PREFIX=/usr install
  # Aqui fazemos staging com DESTDIR do adm.
  make BUILD_STATIC=no PREFIX=/usr DESTDIR="$PKG_DESTDIR" install
}

# Verificação de versão upstream: usa helper genérico do adm
# procurando lz4-*.tar.* em https://github.com/lz4/lz4/releases.
pkg_upstream_version() {
  adm_generic_upstream_version
}
