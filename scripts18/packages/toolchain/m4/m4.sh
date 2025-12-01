#!/usr/bin/env bash
# Build M4-1.4.20 (LFS 12.4, capítulo 6.2) para o adm
set -euo pipefail

# Ambiente esperado para ferramentas temporárias
: "${LFS:?Variável LFS não definida}"
: "${LFS_SOURCES_DIR:?Variável LFS_SOURCES_DIR não definida}"
: "${LFS_TGT:?Variável LFS_TGT não definida}"

PKG_NAME="m4"
PKG_VER="1.4.20"
TARBALL="${PKG_NAME}-${PKG_VER}.tar.xz"
URL="https://ftp.gnu.org/gnu/m4/${TARBALL}"
# MD5 oficial do LFS 12.4
TARBALL_MD5="6eb2ebed5b24e74b6e890919331d2132"

SRC_DIR="${LFS_SOURCES_DIR}"
PKG_SRC_DIR="${SRC_DIR}/${PKG_NAME}-${PKG_VER}"

log()   { echo "==> [${PKG_NAME}] $*"; }
error() { echo "ERRO [${PKG_NAME}]: $*" >&2; exit 1; }

# Não rodar como root (ferramentas temporárias são com usuário 'lfs')
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    error "não execute este script como root; use o usuário de build (ex: 'lfs')"
fi

fetch_tarball() {
    mkdir -p "${SRC_DIR}"

    local dst="${SRC_DIR}/${TARBALL}"
    if [[ -f "${dst}" ]]; then
        log "Tarball já existe: ${dst}"
        return 0
    fi

    log "Baixando ${TARBALL} de ${URL} ..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL -o "${dst}" "${URL}" \
            || error "Falha ao baixar ${URL} com curl"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${dst}" "${URL}" \
            || error "Falha ao baixar ${URL} com wget"
    else
        error "nem curl nem wget encontrados para baixar o tarball"
    fi
}

check_md5() {
    local file="${SRC_DIR}/${TARBALL}"

    if ! command -v md5sum >/dev/null 2>&1; then
        log "md5sum não encontrado; NÃO será feita verificação de integridade (use por sua conta e risco)."
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
        log "Diretório de fontes já existe: ${PKG_SRC_DIR}"
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

main() {
    log "Iniciando build de ${PKG_NAME}-${PKG_VER}"
    log "LFS             = ${LFS}"
    log "LFS_SOURCES_DIR = ${LFS_SOURCES_DIR}"
    log "LFS_TGT         = ${LFS_TGT}"

    ensure_source_dir

    cd "${PKG_SRC_DIR}"

    # Limpa build antigo se existir
    if [[ -d build ]]; then
        rm -rf build
    fi
    mkdir -v build
    cd build

    # Instruções literais do LFS 12.4 cap. 6.2:
    #   ./configure --prefix=/usr   \
    #               --host=$LFS_TGT \
    #               --build=$(build-aux/config.guess)
    log "Configurando (cross temporary tool) ..."
    ../configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$("../build-aux/config.guess")"

    log "Compilando ..."
    make

    log "Instalando em DESTDIR=${LFS} ..."
    make DESTDIR="${LFS}" install

    log "Build e instalação de ${PKG_NAME}-${PKG_VER} concluídos com sucesso."

    # Opcional: grava .version no diretório do script, para o adm
    if [[ -n "${ADM_PKG_META_DIR:-}" ]]; then
        :
        # o adm pega versão de $LFS/packages/cross/m4/m4.version,
        # então gravar esse arquivo é feito fora (veja abaixo).
    fi
}

main "$@"
