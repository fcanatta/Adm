#!/usr/bin/env bash
# Build Libstdc++ oriundo de GCC-15.2.0 para o adm
#
# Baseado na seção 5.6 do LFS 12.4:
#   - usa os fontes do gcc-15.2.0
#   - configura ../libstdc++-v3
#   - --host=$LFS_TGT, --build=$(../config.guess), --prefix=/usr
#   - DESTDIR=$LFS
#   - remove lib{stdc++{,exp,fs},supc++}.la em $LFS/usr/lib
#
# Este script só aceita:
#   ADM_PROFILE="cross-pass1"
#
# Porque este passo é parte do capítulo 5 (conjunto cruzado de ferramentas),
# ainda fora do chroot, com toolchain em $LFS/tools.
#
# Referência: LFS 12.4, capítulo 5.6 "Libstdc++ oriundo de GCC-15.2.0".

set -euo pipefail

: "${LFS:?Variável LFS não definida}"
: "${LFS_SOURCES_DIR:?Variável LFS_SOURCES_DIR não definida}"

PKG_NAME="libstdc++"
GCC_VER="15.2.0"
GCC_DIR="gcc-${GCC_VER}"
TARBALL="${GCC_DIR}.tar.xz"
URL="https://ftp.gnu.org/gnu/gcc/${GCC_DIR}/${TARBALL}"

# MD5 do gcc-15.2.0 (mesmo usado no gcc.sh)
TARBALL_MD5="b861b092bf1af683c46a8aa2e689a6fd"

SRC_DIR="${LFS_SOURCES_DIR}"
PKG_SRC_DIR="${SRC_DIR}/${GCC_DIR}"

log()   { echo "==> [${PKG_NAME}] $*"; }
error() { echo "ERRO [${PKG_NAME}]: $*" >&2; exit 1; }

# -------------------------------------------------------------
#  Seleção de perfil — só cross-pass1
# -------------------------------------------------------------

select_profile() {
    local profile="${ADM_PROFILE:-cross-pass1}"

    case "$profile" in
        cross-pass1)
            BUILD_MODE="cross-libstdc++"

            # LFS_TGT deve estar definido nesse perfil (cross-pass1.env)
            LFS_TGT="${LFS_TGT:-${ADM_TGT:-}}"
            if [[ -z "${LFS_TGT}" ]]; then
                error "LFS_TGT não definido. No perfil cross-pass1.env, defina:
  export LFS_TGT=\"\$(uname -m)-lfs-linux-gnu\""
            fi

            LIBSTD_HOST="${LFS_TGT}"
            LIBSTD_BUILD=""   # preenchido em configure a partir de ../config.guess
            LIBSTD_PREFIX="/usr"
            LIBSTD_DESTDIR="${LFS}"

            # Caminho de headers C++ que o LFS usa nesse estágio:
            GXX_INCLUDE_DIR="/tools/${LFS_TGT}/include/c++/${GCC_VER}"
            ;;

        *)
            error "ADM_PROFILE='$profile' inválido para ${PKG_NAME}.
Este script implementa a etapa 'Libstdc++ oriundo de GCC-${GCC_VER}' do capítulo 5 do LFS,
que é estritamente cross-toolchain. Use ADM_PROFILE='cross-pass1'."
            ;;
    esac

    log "Perfil selecionado: ${profile} (BUILD_MODE=${BUILD_MODE})"
    log "  LFS_TGT          = ${LFS_TGT}"
    log "  LIBSTD_HOST      = ${LIBSTD_HOST}"
    log "  LIBSTD_PREFIX    = ${LIBSTD_PREFIX}"
    log "  LIBSTD_DESTDIR   = ${LIBSTD_DESTDIR}"
    log "  GXX_INCLUDE_DIR  = ${GXX_INCLUDE_DIR}"
}

# -------------------------------------------------------------
#  Download, checksum, extração (gcc-15.2.0)
# -------------------------------------------------------------

fetch_tarball() {
    mkdir -p "${SRC_DIR}"

    local dst="${SRC_DIR}/${TARBALL}"
    if [[ -f "${dst}" ]]; then
        log "Tarball gcc já existe: ${dst}"
        return 0
    fi

    log "Baixando ${TARBALL} de ${URL} ..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL -o "${dst}" "${URL}" \
            || error "falha ao baixar ${URL} com curl"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${dst}" "${URL}" \
            || error "falha ao baixar ${URL} com wget"
    else
        error "nem curl nem wget encontrados para baixar o tarball"
    fi
}

check_md5() {
    local file="${SRC_DIR}/${TARBALL}"

    if [[ -z "${TARBALL_MD5}" ]]; then
        log "TARBALL_MD5 vazio; pulando verificação de MD5."
        return 0
    fi

    if ! command -v md5sum >/dev/null 2>&1; then
        log "md5sum não encontrado; NÃO será feita verificação de integridade."
        return 0
    fi

    if [[ ! -f "${file}" ]]; then
        error "arquivo ${file} não existe para verificar MD5"
    fi

    log "Verificando MD5 de ${file} ..."
    local expected actual
    expected="${TARBALL_MD5}"
    actual="$(md5sum "${file}" | awk '{print $1}')"

    if [[ "${actual}" != "${expected}" ]]; then
        error "MD5 incorreto para ${file}
  Esperado: ${expected}
  Obtido..: ${actual}
Apague o tarball e tente novamente."
    fi

    log "MD5 OK (${actual})"
}

ensure_source_dir() {
    if [[ -d "${PKG_SRC_DIR}" ]]; then
        log "Diretório dos fontes do GCC já existe: ${PKG_SRC_DIR}"
        return 0
    fi

    fetch_tarball
    check_md5

    log "Extraindo ${TARBALL} em ${SRC_DIR} ..."
    tar -xf "${SRC_DIR}/${TARBALL}" -C "${SRC_DIR}"

    if [[ ! -d "${PKG_SRC_DIR}" ]]; then
        error "diretório ${PKG_SRC_DIR} não encontrado após extração"
    fi
}

# -------------------------------------------------------------
#  Configuração, compilação, instalação do Libstdc++
# -------------------------------------------------------------

configure_libstdcxx() {
    cd "${PKG_SRC_DIR}"

    if [[ ! -d libstdc++-v3 ]]; then
        error "Diretório libstdc++-v3 não encontrado dentro de ${PKG_SRC_DIR}"
    fi

    rm -rf build-libstdcxx
    mkdir -v build-libstdcxx
    cd build-libstdcxx

    log "Configurando Libstdc++ (a partir de GCC-${GCC_VER}) ..."
    log "  host=${LIBSTD_HOST}"
    log "  build=$(../config.guess)"
    log "  prefix=${LIBSTD_PREFIX}"
    log "  DESTDIR=${LIBSTD_DESTDIR}"
    log "  --with-gxx-include-dir=${GXX_INCLUDE_DIR}"

    ../libstdc++-v3/configure      \
        --host="${LIBSTD_HOST}"    \
        --build="$(../config.guess)" \
        --prefix="${LIBSTD_PREFIX}" \
        --disable-multilib         \
        --disable-nls              \
        --disable-libstdcxx-pch    \
        --with-gxx-include-dir="${GXX_INCLUDE_DIR}"
}

build_libstdcxx() {
    cd "${PKG_SRC_DIR}/build-libstdcxx"
    log "Compilando Libstdc++ ..."
    make
}

install_libstdcxx() {
    cd "${PKG_SRC_DIR}/build-libstdcxx"

    log "Instalando Libstdc++ com DESTDIR=${LIBSTD_DESTDIR} ..."
    make DESTDIR="${LIBSTD_DESTDIR}" install

    # Remover .la que atrapalham compilação cruzada, como no LFS
    log "Removendo arquivos .la de libstdc++ em ${LIBSTD_DESTDIR}/usr/lib ..."
    rm -vf "${LIBSTD_DESTDIR}/usr/lib/lib"{stdc++{,exp,fs},supc++}.la 2>/dev/null || true

    log "Instalação da Libstdc++ (target) concluída em ${LIBSTD_DESTDIR}/usr."
}

main() {
    log "Iniciando build de ${PKG_NAME} (Libstdc++ from GCC-${GCC_VER})"

    select_profile
    ensure_source_dir
    configure_libstdcxx
    build_libstdcxx
    install_libstdcxx

    log "Libstdc++ (GCC-${GCC_VER}) instalada com sucesso (BUILD_MODE=${BUILD_MODE})."
    log "Bibliotecas e headers estão em ${LIBSTD_DESTDIR}/usr para o alvo ${LFS_TGT}."
}

main "$@"
