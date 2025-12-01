#!/usr/bin/env bash
# Build Ncurses-6.5-20250809 (LFS 12.4, Capítulo 6.3) para o adm
set -euo pipefail

# Ambiente esperado para ferramentas temporárias
: "${LFS:?Variável LFS não definida}"
: "${LFS_SOURCES_DIR:?Variável LFS_SOURCES_DIR não definida}"
: "${LFS_TGT:?Variável LFS_TGT não definida}"

PKG_NAME="ncurses"
PKG_VER="6.5-20250809"
TARBALL="${PKG_NAME}-${PKG_VER}.tgz"
URL="https://invisible-mirror.net/archives/ncurses/current/${TARBALL}"
# MD5 oficial do tarball Ncurses-6.5-20250809
TARBALL_MD5="679987405412f970561cc85e1e6428a2"

SRC_DIR="${LFS_SOURCES_DIR}"
PKG_SRC_DIR="${SRC_DIR}/${PKG_NAME}-${PKG_VER}"

log()   { echo "==> [${PKG_NAME}] $*"; }
error() { echo "ERRO [${PKG_NAME}]: $*" >&2; exit 1; }

# Ferramentas temporárias não devem ser construídas como root
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

build_host_tic() {
    # Passo "tic no host" (LFS 6.3.1)
    log "Construindo 'tic' no anfitrião e instalando em $LFS/tools/bin ..."

    cd "${PKG_SRC_DIR}"

    # usa build separado como no livro
    rm -rf build
    mkdir -v build
    pushd build >/dev/null

    ../configure --prefix="${LFS}/tools" AWK=gawk

    make -C include
    make -C progs tic

    install -v progs/tic "${LFS}/tools/bin"

    popd >/dev/null
}

configure_cross() {
    # Configuração principal (dentro do source dir, não em build/)
    cd "${PKG_SRC_DIR}"

    log "Configurando Ncurses (cross temporary tool) ..."
    ./configure --prefix=/usr                \
                --host="${LFS_TGT}"         \
                --build="$(./config.guess)" \
                --mandir=/usr/share/man     \
                --with-manpage-format=normal \
                --with-shared               \
                --without-normal            \
                --with-cxx-shared           \
                --without-debug             \
                --without-ada               \
                --disable-stripping         \
                AWK=gawk
}

build_and_install() {
    cd "${PKG_SRC_DIR}"

    log "Compilando Ncurses ..."
    make

    log "Instalando em DESTDIR=${LFS} ..."
    make DESTDIR="${LFS}" install

    log "Criando symlink libncurses.so → libncursesw.so ..."
    ln -sv libncursesw.so "${LFS}/usr/lib/libncurses.so"

    log "Ajustando curses.h para sempre usar ABI wide-char ..."
    sed -e 's/^#if.*XOPEN.*$/#if 1/' \
        -i "${LFS}/usr/include/curses.h"
}

main() {
    log "Iniciando build de ${PKG_NAME}-${PKG_VER}"
    log "LFS             = ${LFS}"
    log "LFS_SOURCES_DIR = ${LFS_SOURCES_DIR}"
    log "LFS_TGT         = ${LFS_TGT}"

    ensure_source_dir
    build_host_tic
    configure_cross
    build_and_install

    log "Build e instalação de ${PKG_NAME}-${PKG_VER} concluídos com sucesso."
}

main "$@"
