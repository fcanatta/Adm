# man-pages-6.16 - Linux man-pages (LFS r12.4-46, cap. 8.3)

PKG_NAME="man-pages"
PKG_VERSION="6.16"
PKG_RELEASE="1"

# Grupos de conveniência – ajuste ao seu esquema
PKG_GROUPS="core docs"

PKG_DESC="Coleção principal de man pages do Linux (sections 2,3,4,5,7)"
PKG_URL="https://www.kernel.org/doc/man-pages/"
PKG_LICENSE="various-free-licenses"

# Fonte principal, conforme capítulo 3.2 do LFS r12.4-46
# Download e MD5 tirados direto da tabela de pacotes.
PKG_SOURCES="https://www.kernel.org/pub/linux/docs/man-pages/man-pages-${PKG_VERSION}.tar.xz"
PKG_MD5S="4394eac3258137c8b549febeb04a7c33"

# Dependências lógicas (para uso das manpages).
# Ajuste o nome conforme o seu recipe de man viewer (por ex. 'man-db').
PKG_DEPENDS="man-db"

###############################################################################
# Etapas conforme LFS 8.3 Man-pages-6.16
# LFS manda:
#   rm -v man3/crypt*
#   make -R GIT=false prefix=/usr install
###############################################################################

pkg_prepare() {
  # Aqui o adm já deve ter extraído o tarball e cd para o diretório fonte,
  # algo como: $PWD = man-pages-6.16

  # Remover as páginas de man de crypt*, pois o libxcrypt fornece versões melhores
  # (LFS 8.3.1) 
  rm -v man3/crypt*
}

pkg_build() {
  # man-pages não precisa de etapa de compilação; é basicamente instalação de arquivos.
  :
}

pkg_check() {
  # Não há suite de testes no LFS para esse pacote.
  :
}

pkg_install() {
  # O LFS usa:
  #   make -R GIT=false prefix=/usr install
  # Aqui adaptamos para usar DESTDIR do adm, mantendo -R e GIT=false.
  #
  # -R       : desativa variáveis built-in do make, necessárias porque o build
  #            system do man-pages não lida bem com elas.
  # GIT=false: evita spam de "git: command not found".
  #
  # prefix=/usr             → instala em /usr/share/man etc.
  # DESTDIR="$PKG_DESTDIR"  → faz instalação “staged” dentro do root do pacote.
  make -R GIT=false prefix=/usr DESTDIR="$PKG_DESTDIR" install
}

# Usa o helper genérico do adm para achar a MAIOR versão disponível em kernel.org
# com padrão man-pages-*.tar.{xz,gz}.  O core do adm depois compara com PKG_VERSION
# e escolhe a maior para decidir upgrades.
pkg_upstream_version() {
  adm_generic_upstream_version
}
