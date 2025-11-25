#!/usr/bin/env bash
# Recipe glibc-config para o adm
# Somente configuração pós-instalação da glibc:
#  - /etc/nsswitch.conf
#  - /etc/ld.so.conf e /etc/ld.so.conf.d
#  - /etc/localtime (opcional, via ADM_TIMEZONE ou padrão UTC)

PKG_NAME="glibc-config"
PKG_VERSION="2.42"
PKG_CATEGORY="core"
PKG_DESCRIPTION="Configurações pós-instalação da glibc (nsswitch, ld.so.conf, timezone)."

# Sem fontes reais: recipe puramente de configuração
PKG_URLS=()
PKG_MD5S=()
PKG_SHA256S=()

PKG_DEPENDS_BUILD=("glibc")
PKG_DEPENDS_RUNTIME=("glibc" "tzdata")

PKG_GROUPS=("core")

pkg_source_dir()
{
    # Não há fonte; devolvemos um diretório dummy só pra agradar o adm
    printf '%s\n' "${ADM_BUILD_ROOT:-/var/cache/adm/build}/${PKG_NAME}-${PKG_VERSION}"
}

pkg_fetch()
{
    # Nada para baixar
    :
}

pkg_extract()
{
    # Nada para extrair
    :
}

pkg_build()
{
    # Nada para compilar
    :
}

pkg_install()
{
    local destdir="${DESTDIR:-/}"

    # 8.5.2.1 - /etc/nsswitch.conf 6
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

    # 8.5.2.3 - /etc/ld.so.conf e include /etc/ld.so.conf.d/*.conf 7
    cat > "${destdir}/etc/ld.so.conf" << "EOF"
# Begin /etc/ld.so.conf
/usr/local/lib
/opt/lib
# Add an include directory
include /etc/ld.so.conf.d/*.conf
# End /etc/ld.so.conf
EOF

    mkdir -pv "${destdir}/etc/ld.so.conf.d"

    # /etc/localtime:
    # Se ADM_TIMEZONE estiver definido (ex: America/Sao_Paulo), usa ele.
    # Caso contrário, padroniza em UTC para não depender de interação.
    local tz="${ADM_TIMEZONE:-UTC}"
    if [ -e "${destdir}/usr/share/zoneinfo/${tz}" ]; then
        ln -sfv "/usr/share/zoneinfo/${tz}" "${destdir}/etc/localtime"
    else
        # fallback duro para UTC se o timezone informado não existir no DESTDIR
        if [ -e "${destdir}/usr/share/zoneinfo/UTC" ]; then
            ln -sfv "/usr/share/zoneinfo/UTC" "${destdir}/etc/localtime"
        fi
    fi
}

pkg_post_install()
{
    # Em um sistema real (sem DESTDIR), seria interessante rodar ldconfig.
    # O adm provavelmente já cuida disso em outro lugar, então deixamos vazio.
    :
}

# Versão "upstream" acompanha a versão da glibc na página de pacotes do LFS. 8
pkg_upstream_version()
{
    local url html ver

    url="https://www.linuxfromscratch.org/lfs/view/12.4/chapter03/packages.html"
    if html="$(adm_http_get "${url}" 2>/dev/null)"; then
        ver="$(
            printf '%s\n' "${html}" |
            sed -n 's/.*Glibc (\([0-9][0-9.]*\)).*/\1/p' |
            head -n1
        )"
        if [ -n "${ver}" ]; then
            printf '%s\n' "${ver}"
            return 0
        fi
    fi

    # fallback: usa a versão atual embutida
    printf '%s\n' "${PKG_VERSION}"
}
