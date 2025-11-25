# Recipe para adm: glibc-config
# Só configura:
#   - /etc/nsswitch.conf
#   - /etc/ld.so.conf e /etc/ld.so.conf.d
#   - /etc/localtime (usando ADM_TIMEZONE ou UTC)

PKG_NAME="glibc-config"
PKG_VERSION="1"
PKG_RELEASE="1"

PKG_DESC="Configurações pós-instalação da glibc (nsswitch, ld.so.conf, timezone)"
PKG_URL="(local)"
PKG_LICENSE="custom"
PKG_GROUPS="core"

# Sem fontes: nada pra baixar
PKG_SOURCES=""
PKG_MD5S=""
PKG_SHA256S=""

# Depende de glibc e tzdata já instalados
PKG_DEPENDS="glibc tzdata"

pkg_prepare() {
  :
}

pkg_build() {
  :
}

pkg_install() {
  local destdir="${PKG_DESTDIR}"

  # /etc/nsswitch.conf
  mkdir -p "${destdir}/etc"
  cat > "${destdir}/etc/nsswitch.conf" << "EOF"
# Begin /etc/nsswitch.conf
passwd: files
group: files
shadow: files
hosts: files dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
# End /etc/nsswitch.conf
EOF

  # /etc/ld.so.conf
  cat > "${destdir}/etc/ld.so.conf" << "EOF"
# Begin /etc/ld.so.conf
/usr/local/lib
/opt/lib
# Add an include directory
include /etc/ld.so.conf.d/*.conf
# End /etc/ld.so.conf
EOF

  mkdir -pv "${destdir}/etc/ld.so.conf.d"

  # /etc/localtime – aqui só ajustamos se ainda não foi tratado por tzdata
  local tzname="${ADM_TIMEZONE:-UTC}"
  local zonefile="${PKG_PREFIX:-/usr}/share/zoneinfo/${tzname}"

  if [[ -e "${destdir}${zonefile}" ]]; then
    ln -sfv "${zonefile}" "${destdir}/etc/localtime"
  else
    if [[ -e "${destdir}${PKG_PREFIX:-/usr}/share/zoneinfo/UTC" ]]; then
      ln -sfv "${PKG_PREFIX:-/usr}/share/zoneinfo/UTC" "${destdir}/etc/localtime"
    fi
  fi
}

pkg_upstream_version() {
  # Não tem “upstream” separado; segue a da glibc no LFS.
  printf '%s\n' "$PKG_VERSION"
}
