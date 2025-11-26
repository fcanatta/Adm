# Xz-5.8.1 - XZ Utils (LFS r12.4-46, cap. 8.8)

PKG_NAME="xz"
PKG_VERSION="5.8.1"
PKG_RELEASE="1"

PKG_GROUPS="core libs"

PKG_DESC="XZ Utils: biblioteca liblzma e ferramentas xz/lzma para compressão de alta taxa"
PKG_URL="https://tukaani.org/xz"
PKG_LICENSE="GPL-2.0-or-later AND LGPL-2.1-or-later"

# Dados de pacote conforme LFS 12.4:
#   Home page: https://tukaani.org/xz
#   Download:  https://github.com//tukaani-project/xz/releases/download/v5.8.1/xz-5.8.1.tar.xz
#   MD5:       cf5e1feb023d22c6bdaa30e84ef3abe3
PKG_SOURCES="https://github.com/tukaani-project/xz/releases/download/v${PKG_VERSION}/xz-${PKG_VERSION}.tar.xz"
PKG_MD5S="cf5e1feb023d22c6bdaa30e84ef3abe3"

# Dependências lógicas mínimas (ajuste nomes conforme seus outros recipes)
PKG_DEPENDS="glibc zlib bzip2"

###############################################################################
# 8.8.1. Installation of Xz (adaptado para o adm)
#
# LFS:
#   ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/xz-5.8.1
#   make
#   make check
#   make install
###############################################################################

pkg_prepare() {
  # Diretório fonte: xz-5.8.1/

  ./configure \
    --prefix=/usr \
    --disable-static \
    --docdir="/usr/share/doc/${PKG_NAME}-${PKG_VERSION}"
}

pkg_build() {
  make
}

pkg_check() {
  # Suite de testes oficial – é rápida, vale a pena rodar
  make check
}

pkg_install() {
  # Instalação em staging via DESTDIR para o adm
  make DESTDIR="$PKG_DESTDIR" install
}

# Descoberta de versão upstream:
# usa o helper genérico do adm para olhar o diretório de releases do xz
# (xz-*.tar.*) e pegar a MAIOR versão disponível. O core do adm compara
# isso com PKG_VERSION e decide upgrades.
pkg_upstream_version() {
  adm_generic_upstream_version
}
