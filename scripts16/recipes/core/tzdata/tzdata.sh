# Recipe para adm: tzdata-2025b
# Caminho sugerido: /var/lib/adm/recipes/core/tzdata/tzdata.sh

PKG_NAME="tzdata"
PKG_VERSION="2025b"
PKG_RELEASE="1"

PKG_DESC="Banco de dados de fuso horário da IANA (tzdata ${PKG_VERSION})"
PKG_URL="https://www.iana.org/time-zones"
PKG_LICENSE="public-domain"
PKG_GROUPS="core"

# Fonte (ajuste a versão/URL conforme o que você estiver usando no LFS)
PKG_SOURCES="https://www.iana.org/time-zones/repository/releases/tzdata${PKG_VERSION}.tar.gz"

# Só temos MD5 confiável; SHA256 é opcional.
# Como seu adm exige que o número de itens em PKG_MD5S/PKG_SHA256S
# seja 0 ou igual ao de PKG_SOURCES, vou usar só MD5.
PKG_MD5S="ad65154c48c74a9b311fe84778c5434f"
PKG_SHA256S=""

# Depende de glibc, porque precisa do zic e da árvore de /usr/share/zoneinfo
PKG_DEPENDS="glibc"

pkg_prepare() {
  # tzdata não precisa de patches; só garantir que estamos no dir certo
  :
}

pkg_build() {
  # Não há compilação; tudo é feito na instalação via zic
  :
}

pkg_install() {
  # Estamos dentro do diretório extraído do tarball (tzdata${PKG_VERSION})
  # O adm já chamou pkg_build dentro desse diretório.

  local destdir="${PKG_DESTDIR}"
  local zoneinfo="${destdir}${PKG_PREFIX:-/usr}/share/zoneinfo"

  mkdir -pv "${zoneinfo}"/{posix,right}

  # Lista de arquivos de zonas, como no LFS
  local tz
  for tz in etcetera southamerica northamerica europe africa antarctica \
            asia australasia backward; do
    zic -L /dev/null   -d "${zoneinfo}"        "${tz}"
    zic -L /dev/null   -d "${zoneinfo}/posix"  "${tz}"
    zic -L leapseconds -d "${zoneinfo}/right"  "${tz}"
  done

  cp -v zone.tab zone1970.tab iso3166.tab "${zoneinfo}"

  # Define "posixrules" (LFS usa America/New_York)
  zic -d "${zoneinfo}" -p America/New_York

  # /etc/localtime: faça aqui com timezone configurável:
  # se ADM_TIMEZONE não existir, usa UTC.
  local tzname="${ADM_TIMEZONE:-UTC}"
  local target_zone="${PKG_PREFIX:-/usr}/share/zoneinfo/${tzname}"

  if [[ -e "${destdir}${target_zone}" ]]; then
    mkdir -p "${destdir}/etc"
    ln -sfv "${target_zone}" "${destdir}/etc/localtime"
  else
    # Fallback para UTC se o timezone pedido não existir
    if [[ -e "${destdir}${PKG_PREFIX:-/usr}/share/zoneinfo/UTC" ]]; then
      mkdir -p "${destdir}/etc"
      ln -sfv "${PKG_PREFIX:-/usr}/share/zoneinfo/UTC" "${destdir}/etc/localtime"
    fi
  fi
}

pkg_upstream_version() {
  # Versão do tzdata normalmente é algo como 2025b, 2025c...
  # Aqui vou fazer algo simples: tentar ler a página de releases da IANA
  # e pegar a maior versão. Se falhar, volta PKG_VERSION.

  local url="https://ftp.iana.org/tz/releases/"
  local latest

  if command -v curl >/dev/null 2>&1; then
    latest="$(
      curl -fsSL "$url" \
        | sed -n 's/.*tzdata\([0-9][0-9][0-9][0-9][a-z]\)\.tar\.gz.*/\1/p' \
        | sort -V \
        | tail -n1
    )"
  fi

  if [[ -n "$latest" ]]; then
    printf '%s\n' "$latest"
  else
    printf '%s\n' "$PKG_VERSION"
  fi
}
