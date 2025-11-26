# zlib-1.3.1 - Biblioteca de compressão (LFS r12.4-46, cap. 8.6)

PKG_NAME="zlib"
PKG_VERSION="1.3.1"
PKG_RELEASE="1"

PKG_GROUPS="core libs"

PKG_DESC="Biblioteca de compressão e descompressão zlib, usada por diversos programas"
PKG_URL="https://zlib.net/"
PKG_LICENSE="zlib-acknowledgement"

# Dados tirados da tabela de pacotes do LFS 12.4:
#   Home page: https://zlib.net/
#   Download:  https://zlib.net/fossils/zlib-1.3.1.tar.gz
#   MD5 sum:   9855b6d802d7fe5b7bd5b196a2271655 1
PKG_SOURCES="https://zlib.net/fossils/zlib-${PKG_VERSION}.tar.gz"
PKG_MD5S="9855b6d802d7fe5b7bd5b196a2271655"

# Dependências lógicas
# (no livro, zlib vem depois de glibc; aqui modelamos essa dependência)
PKG_DEPENDS="glibc"

###############################################################################
# 8.6.1. Installation of Zlib (adaptado para o adm)
#
# LFS:
#   ./configure --prefix=/usr
#   make
#   make check
#   make install
#   rm -fv /usr/lib/libz.a
###############################################################################

pkg_prepare() {
  # Diretório fonte já extraído, por ex.: zlib-1.3.1/

  ./configure --prefix=/usr
}

pkg_build() {
  # Compila a biblioteca compartilhada
  make
}

pkg_check() {
  # Testes da zlib – rápidos e recomendados
  make check
}

pkg_install() {
  # Instala em staging via DESTDIR
  #
  # LFS:   make install
  # Aqui:  make DESTDIR="$PKG_DESTDIR" install
  make DESTDIR="$PKG_DESTDIR" install

  # Remover a lib estática inútil, como manda o livro:
  #
  # LFS faz:
  #   rm -fv /usr/lib/libz.a
  #
  # Aqui fazemos o equivalente dentro do DESTDIR:
  rm -fv "$PKG_DESTDIR/usr/lib/libz.a" || true
}

# Descoberta de versão upstream:
# usa o helper genérico do adm para olhar o diretório de fontes
# (https://zlib.net/fossils/) e escolher a MAIOR versão disponível
# que bate com o padrão zlib-*.tar.*.
# O core do adm (upstream_version_for) ainda compara com PKG_VERSION
# e usa a maior para decidir upgrades.
pkg_upstream_version() {
  adm_generic_upstream_version
}
