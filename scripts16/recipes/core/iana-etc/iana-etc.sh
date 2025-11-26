# Recipe para adm: Iana-Etc-20251022
# Caminho sugerido: /var/lib/adm/recipes/core/iana-etc/iana-etc.sh
# Iana-Etc-20251022 - Tabelas de serviços e protocolos (LFS r12.4-46, cap. 8.4)

PKG_NAME="iana-etc"
PKG_VERSION="20251022"
PKG_RELEASE="1"

PKG_GROUPS="core network"

PKG_DESC="Arquivos /etc/services e /etc/protocols a partir dos dados da IANA"
PKG_URL="https://www.iana.org/protocols"
PKG_LICENSE="public-domain-like"

PKG_SOURCES="https://github.com/Mic92/iana-etc/releases/download/${PKG_VERSION}/iana-etc-${PKG_VERSION}.tar.gz"
PKG_MD5S="6d3bd72a4ffa0a2cab2065c25677a9b8"

PKG_DEPENDS=""

###############################################################################
# Checks adicionados
###############################################################################

pkg_prepare() {
  # Verifica existência dos arquivos essenciais
  if [[ ! -f services ]]; then
    die "Arquivo 'services' não encontrado no tarball — pacote corrompido?"
  fi
  if [[ ! -f protocols ]]; then
    die "Arquivo 'protocols' não encontrado no tarball — pacote corrompido?"
  fi
}

pkg_build() {
  :
}

pkg_check() {
  # 1. Verifica se estão vazios
  if [[ ! -s services ]]; then
    die "'services' existe, mas está vazio — isso indica falha no download ou corrupção."
  fi
  if [[ ! -s protocols ]]; then
    die "'protocols' existe, mas está vazio — isso indica falha no download ou corrupção."
  fi

  # 2. Verificação muito simples de formato — deve haver linhas com campos.
  # Para services: padrão "<nome> <porta>/<protocolo>"
  if ! grep -Eq '^[a-zA-Z0-9_-]+\s+[0-9]+/(tcp|udp)' services; then
    die "'services' não contém entradas válidas (padrão porta/protocolo não encontrado)."
  fi

  # Para protocols: padrão "<nome> <número>"
  if ! grep -Eq '^[a-zA-Z0-9_-]+\s+[0-9]+' protocols; then
    die "'protocols' não contém entradas válidas (número de protocolo não encontrado)."
  fi

  log_info "Checks OK: services e protocols parecem válidos."
}

pkg_install() {
  install -d "$PKG_DESTDIR/etc"

  install -m644 services   "$PKG_DESTDIR/etc/services"
  install -m644 protocols  "$PKG_DESTDIR/etc/protocols"

  log_info "Instalados: /etc/services e /etc/protocols"
}

# PKG_VERSION e escolhe o maior entre os dois.
pkg_upstream_version() {
  adm_generic_upstream_version
}
