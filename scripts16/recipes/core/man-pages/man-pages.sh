# Recipe para adm: man-pages-6.16
# Caminho sugerido: /var/lib/adm/recipes/core/man-pages/man-pages.sh
# man-pages - Linux manual pages (LFS r12.4-46)
# Fonte: LFS 8.3 Man-pages-6.16
# https://www.linuxfromscratch.org/lfs/view/development/chapter08/man-pages.html

PKG_NAME="man-pages"
PKG_VERSION="6.16"
PKG_RELEASE="1"
PKG_GROUPS="core"
PKG_DESC="Coleção de páginas de manual para Linux (kernel + glibc)."

# Upstream oficial em kernel.org
PKG_SOURCES="https://www.kernel.org/pub/linux/docs/man-pages/man-pages-6.16.tar.xz"

# SHA-256 oficial do tarball man-pages-6.16.tar.xz
# Referência: sha256sums.asc em kernel.org / Debian manpages_6.16.orig.tar.xz
PKG_SHA256S="8e247abd75cd80809cfe08696c81b8c70690583b045749484b242fb43631d7a3"

# Sem dependências diretas de runtime além da base do sistema
PKG_DEPENDS=""

# Opcional: URL do projeto (não é obrigatório para o adm, mas útil em adm show-meta)
PKG_URL="https://www.kernel.org/pub/linux/docs/man-pages/"

# Etapa de preparação pré-build:
# - Remover man pages de crypt* (libxcrypt fornecerá versões melhores)
pkg_prepare() {
  # O diretório atual aqui é o srcdir extraído (man-pages-6.16)
  rm -v man3/crypt* || true
}

# Não há etapa de compilação propriamente dita; o pacote já vem pronto.
# Definimos pkg_build como no-op para ficar explícito.
pkg_build() {
  :
}

# Também não há testes formais no LFS para este pacote.
pkg_check() {
  :
}

# Instalação:
# LFS manda: make -R GIT=false prefix=/usr install
# Aqui adaptamos para usar DESTDIR, mantendo prefix=/usr.
pkg_install() {
  make -R GIT=false \
    prefix=/usr \
    DESTDIR="$PKG_DESTDIR" \
    install
}

# Opcional: função de upstream simples, caso queira
# que o "adm list-upgrades" funcione apenas com a versão da recipe.
# Se não quiser, pode remover essa função e o adm usará PKG_VERSION.
pkg_upstream_version() {
  printf '%s\n' "$PKG_VERSION"
}
