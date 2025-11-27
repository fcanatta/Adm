#!/usr/bin/env bash
# Recipe man-pages-6.16 para o adm
# Baseado em LFS r12.4-46, capítulo 8.3 (Man-pages-6.16)
# https://www.linuxfromscratch.org/lfs/view/development/chapter08/man-pages.html

PKG_NAME="man-pages"
PKG_VERSION="6.16"
PKG_RELEASE="1"

PKG_DESC="Collection of over 2,400 Linux man pages (sections 2,3,4,5,7)"
PKG_LICENSE="Various (see individual pages)"
PKG_URL="https://www.kernel.org/pub/linux/docs/man-pages/"
PKG_GROUPS="core docs"

# man-pages não tem dependência binária forte; são só arquivos de documentação.
# Se quiser, você pode adicionar 'man-db' aqui, mas no LFS ele vem depois.
PKG_DEPENDS=""

# Fonte oficial (tar.xz) – usamos \$PKG_VERSION para facilitar upgrades
PKG_SOURCES="https://www.kernel.org/pub/linux/docs/man-pages/man-pages-\$PKG_VERSION.tar.xz"

# SHA256 alinhado com o tar.xz acima
# man-pages-6.16.tar.xz
PKG_SHA256S="8e247abd75cd80809cfe08696c81b8c70690583b045749484b242fb43631d7a3"

# Não vamos usar MD5; o adm já valida SHA256 se disponível
PKG_MD5S=""

# -------------------------------------------------------------
# Etapas de build seguindo o livro LFS
# -------------------------------------------------------------

# 8.3.1: antes de instalar, remover as páginas de crypt* (libxcrypt fornece melhores)
pkg_prepare() {
  # Estamos dentro do diretório de origem (man-pages-6.16)
  rm -v man3/crypt* || true
}

# man-pages não precisa de compilação real, só instalação
pkg_build() {
  :
}

# Pacote não vem com suite de testes
pkg_check() {
  :
}

# 8.3.1 LFS: make -R GIT=false prefix=/usr install
# Adaptado para DESTDIR do adm:
#   - prefix  -> \$PKG_PREFIX  (normalmente /usr)
#   - DESTDIR -> \$PKG_DESTDIR (raiz temporária do pacote)
pkg_install() {
  : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"
  : "${PKG_PREFIX:=/usr}"

  make -R GIT=false \
       prefix="$PKG_PREFIX" \
       DESTDIR="$PKG_DESTDIR" \
       install
}

# Opcional: se o teu adm tiver adm_generic_upstream_version(),
# ele já consegue descobrir versões novas só com PKG_SOURCES/PKG_VERSION,
# então não é obrigatório definir pkg_upstream_version() aqui.
