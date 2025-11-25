#!/usr/bin/env bash
# Recipe tzdata-2025b para o adm
# Baseado no LFS 12.4 (Time Zone Data 2025b + seção 8.5.2.2) 0

PKG_NAME="tzdata"
PKG_VERSION="2025b"
PKG_CATEGORY="core"
PKG_DESCRIPTION="Banco de dados de fuso horário da IANA (tzdata ${PKG_VERSION})"

# Fonte e checksum conforme LFS 12.4 (Time Zone Data (2025b)) 1
PKG_URLS=(
  "https://www.iana.org/time-zones/repository/releases/tzdata${PKG_VERSION}.tar.gz"
)

PKG_MD5S=(
  "ad65154c48c74a9b311fe84778c5434f"
)

# SHA256 não é fornecido pelo LFS; deixamos vazio para o adm ignorar essa checagem
PKG_SHA256S=()

# Dependência: precisa do zic (vem do glibc já instalado)
PKG_DEPENDS_BUILD=()
PKG_DEPENDS_RUNTIME=("glibc")

# Se o adm tiver suporte a grupos/categorias, isso ajuda em "adm build core"
PKG_GROUPS=("core")

# Diretório dentro de $ADM_BUILD_ROOT onde o código será extraído
pkg_source_dir()
{
    # Ex: /var/cache/adm/build/tzdata-2025b
    printf '%s\n' "${ADM_BUILD_ROOT:-/var/cache/adm/build}/${PKG_NAME}-${PKG_VERSION}"
}

pkg_fetch()
{
    adm_fetch_sources   # função do adm que baixa e verifica MD5/SHA
}

pkg_extract()
{
    local src_dir
    src_dir="$(pkg_source_dir)"
    mkdir -p "${src_dir}"
    cd "${src_dir%/*}" || return 1

    # Supondo que o adm salva os tarballs em $ADM_SRC_CACHE
    local tarball="${ADM_SRC_CACHE:-/var/cache/adm/src}/tzdata${PKG_VERSION}.tar.gz"

    rm -rf "${src_dir}"
    mkdir -p "${src_dir}"
    tar -xf "${tarball}" -C "${src_dir}"
}

pkg_build()
{
    # tzdata não tem etapa de build tradicional (configure/make).
    # A instalação é feita chamando zic diretamente na etapa pkg_install().
    :
}

pkg_install()
{
    # Instala os arquivos de zoneinfo em $DESTDIR/usr/share/zoneinfo
    # Segue a seção 8.5.2.2 do LFS (Adding Time Zone Data), ajustada para DESTDIR. 2
    local destdir="${DESTDIR:-/}"
    local src_dir
    src_dir="$(pkg_source_dir)"

    cd "${src_dir}" || return 1

    local ZONEINFO="${destdir}/usr/share/zoneinfo"

    mkdir -pv "${ZONEINFO}"/{posix,right}

    # Mesma lista de arquivos usada no livro:
    # etcetera southamerica northamerica europe africa antarctica asia australasia backward
    local tz
    for tz in etcetera southamerica northamerica europe africa antarctica \
              asia australasia backward; do
        zic -L /dev/null   -d "${ZONEINFO}"        "${tz}"
        zic -L /dev/null   -d "${ZONEINFO}/posix"  "${tz}"
        zic -L leapseconds -d "${ZONEINFO}/right"  "${tz}"
    done

    # Tabelas auxiliares
    cp -v zone.tab zone1970.tab iso3166.tab "${ZONEINFO}"

    # Cria posixrules (usa America/New_York, como no LFS)
    zic -d "${ZONEINFO}" -p America/New_York

    # NÃO criamos /etc/localtime aqui para não forçar um timezone específico.
    # Isso fica a cargo de outra recipe (glibc-config) ou de configuração manual.
}

pkg_post_install()
{
    # Nada especial aqui; /etc/localtime será tratado em glibc-config ou manualmente.
    :
}

# Descobre a versão upstream nova do tzdata.
# 1) Tenta extrair do LFS 12.4 (linha "Time Zone Data (2025b)")
# 2) Se falhar, procura no diretório de releases da IANA.
pkg_upstream_version()
{
    local url html ver

    # 1) Página de pacotes do LFS 12.4 3
    url="https://www.linuxfromscratch.org/lfs/view/12.4/chapter03/packages.html"
    if html="$(adm_http_get "${url}" 2>/dev/null)"; then
        ver="$(
            printf '%s\n' "${html}" |
            sed -n 's/.*Time Zone Data (\([0-9][0-9][0-9][0-9][a-z]\)).*/\1/p' |
            head -n1
        )"
        if [ -n "${ver}" ]; then
            printf '%s\n' "${ver}"
            return 0
        fi
    fi

    # 2) Diretório upstream da IANA 4
    url="https://ftp.iana.org/tz/releases/"
    if html="$(adm_http_get "${url}" 2>/dev/null)"; then
        ver="$(
            printf '%s\n' "${html}" |
            sed -n 's/.*tzdb-\([0-9][0-9][0-9][0-9][a-z]\)\.tar.*/\1/p' |
            sort -V | tail -n1
        )"
        # converte tzdb-2025b -> 2025b
        ver="${ver#tzdb-}"
        if [ -n "${ver}" ]; then
            printf '%s\n' "${ver}"
            return 0
        fi
    fi

    return 1
}
