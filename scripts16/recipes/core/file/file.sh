# file-5.46 - utilitário 'file' (LFS r12.4-46, cap. 8.11)

PKG_NAME="file"
PKG_VERSION="5.46"
PKG_RELEASE="1"

PKG_GROUPS="core utils"

PKG_DESC="Utilitário 'file' e biblioteca libmagic para detecção de tipo de arquivo"
PKG_URL="https://www.darwinsys.com/file/"
PKG_LICENSE="BSD-2-Clause-like"

# Dados de pacote conforme LFS 12.4:
#   Home page: https://www.darwinsys.com/file/
#   Download:  https://astron.com/pub/file/file-5.46.tar.gz
#   MD5:       459da2d4b534801e2e2861611d823864
PKG_SOURCES="https://astron.com/pub/file/file-${PKG_VERSION}.tar.gz"
PKG_MD5S="459da2d4b534801e2e2861611d823864"

# Dependências lógicas (ajuste os nomes conforme seus outros recipes do adm)
PKG_DEPENDS="glibc zlib xz zstd bzip2"

###############################################################################
# 8.11.1. Installation of File (adaptado para o adm)
#
# LFS:
#   ./configure --prefix=/usr
#   make
#   make check
#   make install
###############################################################################

pkg_prepare() {
  # Diretório fonte: file-5.46/

  ./configure \
    --prefix=/usr
}

pkg_build() {
  make
}

pkg_check() {
  # Testes oficiais
  make check

  ###########################################################################
  # CHECK EXTRA: garantir que o binário 'file' e libmagic.so foram gerados
  ###########################################################################

  # O binário costuma ficar em 'src/file' no tree de build
  if [[ ! -x "src/file" ]]; then
    die "FALHA: binário 'src/file' não foi gerado após o build!"
  fi

  # A biblioteca compartilhada geralmente fica em src/.libs/libmagic.so*
  if ! ls src/.libs/libmagic.so* >/dev/null 2>&1; then
    die "FALHA: biblioteca compartilhada libmagic.so não foi gerada (src/.libs/libmagic.so* ausente)!"
  fi

  log_info "Check OK: 'file' e libmagic.so foram gerados corretamente."
}

pkg_install() {
  # Instala em staging via DESTDIR (o adm injeta $PKG_DESTDIR)
  make DESTDIR="$PKG_DESTDIR" install
}

# Descoberta de versão upstream:
# usa o helper genérico do adm para olhar o diretório
#   https://astron.com/pub/file/
# procurando padrões file-*.tar.*
# O core do adm compara o resultado com PKG_VERSION e escolhe a maior.
pkg_upstream_version() {
  adm_generic_upstream_version
}
