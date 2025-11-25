# Recipe para adm: Iana-Etc-20251022
# Caminho sugerido: /var/lib/adm/recipes/core/iana-etc/iana-etc.sh

PKG_NAME="iana-etc"
PKG_VERSION="20251022"
PKG_RELEASE="1"

PKG_DESC="Dados de serviços e protocolos de rede (IANA /etc/services e /etc/protocols)"
PKG_URL="https://www.iana.org/protocols"
PKG_LICENSE="custom"
PKG_GROUPS="core"   # se quiser usar em 'adm build core'

# LFS r12.4-46 - capítulo 3.2 All Packages:
# Download + MD5 do tarball oficial
PKG_SOURCES="https://github.com/Mic92/iana-etc/releases/download/20251022/iana-etc-20251022.tar.gz"
PKG_MD5S="6d3bd72a4ffa0a2cab2065c25677a9b8"

# Sem dependências de build específicas
PKG_DEPENDS=""

pkg_prepare() {
  # Nada a preparar: pacote só contém arquivos de dados (services, protocols)
  :
}

pkg_build() {
  # Não há processo de compilação, apenas instalação de arquivos texto
  :
}

pkg_install() {
  # LFS manda: cp services protocols /etc
  # Aqui adaptado para DESTDIR para o adm empacotar antes de instalar de verdade.
  mkdir -p "${PKG_DESTDIR}/etc"

  install -v -m644 services   "${PKG_DESTDIR}/etc/services"
  install -v -m644 protocols "${PKG_DESTDIR}/etc/protocols"
}

# Opcional: por enquanto, upstream == versão da recipe.
# Se quiser, você pode implementar depois algo que leia o site/projeto eache a data mais nova.
pkg_upstream_version() {
  local url="https://github.com/Mic92/iana-etc/releases"
  local latest

  latest="$(
    curl -fsSL "$url" \
      | sed -n 's/.*iana-etc-\([0-9]\{8\}\)\.tar\.gz.*/\1/p' \
      | sort -V \
      | tail -n1
  )"

  # Se extraiu corretamente, devolve a versão
  if [[ -n "$latest" ]]; then
    printf '%s\n' "$latest"
    return 0
  fi

  # Fallback seguro: se o GitHub falhar, retorna a versão atual da recipe
  printf '%s\n' "$PKG_VERSION"
}
