# busybox-1.36.1 - Swiss Army Knife (core/utils + todos os links de applets)

PKG_NAME="busybox"
PKG_VERSION="1.36.1"
PKG_RELEASE="1"

PKG_GROUPS="core utils busybox"

PKG_DESC="BusyBox ${PKG_VERSION}: coleção de utilitários em um único binário, com links para todos os applets."
PKG_URL="https://busybox.net/"
PKG_LICENSE="GPL-2.0-only"

# Fonte oficial:
#   https://busybox.net/downloads/busybox-1.36.1.tar.bz2
# SHA-256 (mesmo tarball usado em Ubuntu orig.tar.bz2):
#   b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314
PKG_SOURCES="https://busybox.net/downloads/busybox-${PKG_VERSION}.tar.bz2"
PKG_SHA256S="b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314"

# Dependências lógicas (ajuste os nomes conforme seus outros recipes)
PKG_DEPENDS="glibc"

###############################################################################
# Notas de build:
# - BusyBox não usa DESTDIR no make install; usa CONFIG_PREFIX.
# - O build gera busybox.links e o "make install" cria symlinks/hardlinks
#   para TODOS os applets compilados, com base nesse arquivo. 2
###############################################################################

pkg_prepare() {
  # Gera defconfig “bem completo”
  make defconfig

  # Ajustes pro adm / rootfs geral
  sed -i 's/^# CONFIG_FEATURE_PREFER_APPLETS is not set/CONFIG_FEATURE_PREFER_APPLETS=y/' .config
  sed -i 's/^# CONFIG_FEATURE_SH_STANDALONE is not set/CONFIG_FEATURE_SH_STANDALONE=y/' .config
  sed -i 's/^# CONFIG_INSTALL_APPLET_SYMLINKS is not set/CONFIG_INSTALL_APPLET_SYMLINKS=y/' .config
  sed -i 's/^CONFIG_INSTALL_APPLET_HARDLINKS=y/# CONFIG_INSTALL_APPLET_HARDLINKS is not set/' .config
  sed -i 's/^CONFIG_INSTALL_APPLET_SCRIPT_WRAPPERS=y/# CONFIG_INSTALL_APPLET_SCRIPT_WRAPPERS is not set/' .config
  sed -i 's/^CONFIG_STATIC=y/# CONFIG_STATIC is not set/' .config

  # Se quiser garantir consistência
  make oldconfig
}

pkg_build() {
  # Compila o binário principal "busybox"
  make
}

pkg_check() {
  # Check básico: o binário precisa existir e responder a --help
  if [[ ! -x busybox ]]; then
    die "FALHA: binário 'busybox' não foi gerado!"
  fi

  ./busybox --help >/dev/null 2>&1 || die "FALHA: 'busybox --help' retornou erro"

  # Teste simples de um applet comum (ls) via chamada direta
  ./busybox ls . >/dev/null 2>&1 || die "FALHA: applet 'ls' do busybox não funcionou"

  log_info "Checks OK: busybox compilado e funcional."
}

pkg_install() {
  # Aqui é a parte importante pro que você pediu:
  #
  # - BusyBox usa CONFIG_PREFIX para decidir ONDE instalar.
  # - "make CONFIG_PREFIX=/path install" instala:
  #     /path/bin/busybox
  #   e cria todos os links para todos os applets compilados
  #   (bin, sbin, usr/bin, usr/sbin, etc) a partir de busybox.links.
  #
  # Então, para instalar no root do pacote ($PKG_DESTDIR), fazemos:

  make CONFIG_PREFIX="$PKG_DESTDIR" install

  # Resultado típico:
  #   $PKG_DESTDIR/bin/busybox
  #   $PKG_DESTDIR/bin/ls -> busybox
  #   $PKG_DESTDIR/bin/sh -> busybox
  #   $PKG_DESTDIR/usr/bin/awk -> ../bin/busybox
  #   ... todos os applets compilados vão ter seus links criados.
  #
  # Se o seu .config estiver setado pra instalar symlinks (o normal),
  # isso já garante "todos os links de todos os programas".
}

# Verificação de versão upstream:
# usa o helper genérico do adm pra olhar https://busybox.net/downloads/
# e pegar a MAIOR busybox-*.tar.* disponível (1.37.0, etc).
# O core do adm compara com PKG_VERSION e decide upgrades.
pkg_upstream_version() {
  adm_generic_upstream_version
}
