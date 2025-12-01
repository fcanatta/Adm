#!/usr/bin/env bash
# Build musl-1.2.5 para o adm (build final, dentro do chroot)
set -euo pipefail

# Em build final, o adm normalmente roda isso DENTRO do chroot
# com LFS="/". Ainda assim, exigimos LFS para manter o padrão.
: "${LFS:?Variável LFS não definida}"

# Se LFS_SOURCES_DIR não estiver setada dentro do chroot,
# caímos em /sources (padrão LFS) ou $LFS/sources.
SRC_DIR="${LFS_SOURCES_DIR:-${LFS%/}/sources}"

PKG_NAME="musl"
PKG_VER="1.2.5"
PKG_DIR="${PKG_NAME}-${PKG_VER}"
TARBALL="${PKG_DIR}.tar.gz"
URL="https://musl.libc.org/releases/${TARBALL}"

# SHA256 oficial (conferido a partir de pgp/signature por distros) 2
TARBALL_SHA256="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

PKG_SRC_DIR="${SRC_DIR}/${PKG_DIR}"

log()   { echo "==> [${PKG_NAME}] $*"; }
error() { echo "ERRO [${PKG_NAME}]: $*" >&2; exit 1; }

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "este script precisa ser executado como root (dentro do chroot)"
    fi
}

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

check_sha256() {
    local file="${SRC_DIR}/${TARBALL}"

    if ! command -v sha256sum >/dev/null 2>&1; then
        log "sha256sum não encontrado; NÃO será feita verificação de integridade (use por sua conta e risco)."
        return 0
    fi

    if [[ ! -f "${file}" ]]; then
        error "arquivo ${file} não existe para verificar SHA256"
    fi

    log "Verificando SHA256 de ${file} ..."
    local expected actual
    expected="${TARBALL_SHA256}"
    actual="$(sha256sum "${file}" | awk '{print $1}')"

    if [[ "${actual}" != "${expected}" ]]; then
        error "SHA256 incorreto para ${file}
  Esperado: ${expected}
  Obtido..: ${actual}
Apague o tarball e tente novamente."
    fi

    log "SHA256 OK (${actual})"
}

ensure_source_dir() {
    if [[ -d "${PKG_SRC_DIR}" ]]; then
        log "Diretório de fontes já existe: ${PKG_SRC_DIR}"
        return 0
    fi

    fetch_tarball
    check_sha256

    log "Extraindo ${TARBALL} em ${SRC_DIR} ..."
    tar -xf "${SRC_DIR}/${TARBALL}" -C "${SRC_DIR}"

    if [[ ! -d "${PKG_SRC_DIR}" ]]; then
        error "diretório ${PKG_SRC_DIR} não encontrado após extração"
    fi
}

configure_musl() {
    cd "${PKG_SRC_DIR}"

    log "Configurando musl-${PKG_VER} ..."
    # Configuração básica conforme INSTALL do musl:
    #   ./configure --prefix=/usr --syslibdir=/lib
    # Ajustamos mandir também.
    ./configure \
        --prefix=/usr \
        --syslibdir=/lib \
        --mandir=/usr/share/man
}

build_musl() {
    cd "${PKG_SRC_DIR}"
    log "Compilando musl ..."
    make
}

install_musl() {
    cd "${PKG_SRC_DIR}"
    log "Instalando musl em /usr e /lib ..."
    make install

    # Opcional: garantir que o ld-musl e libc.so estejam em /lib (normalmente já estão)
    # e ajustar permissões se necessário. A instalação padrão do musl já faz:
    #   /lib/ld-musl-$(ARCH).so.1
    #   /lib/libc.so
    # Portanto aqui, em geral, não é preciso mexer.

    log "Instalação de musl-${PKG_VER} concluída."
}

main() {
    require_root

    log "Iniciando build de ${PKG_NAME}-${PKG_VER} (final, libc principal)"
    log "LFS         = ${LFS}"
    log "SRC_DIR     = ${SRC_DIR}"

    ensure_source_dir
    configure_musl
    build_musl
    install_musl

    log "musl-${PKG_VER} instalado com sucesso."
    log "ATENÇÃO: Todas as libs C existentes/devem ser compatíveis com musl; revise toolchain/binutils/GCC."
}

main "$@"
