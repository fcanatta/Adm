#!/usr/bin/env bash
# Build Binutils-2.45.1 (LFS 12.4 final) para o adm,
# usando DESTDIR e empacotando em .tar.zst
set -euo pipefail

: "${LFS:?Variável LFS não definida}"
: "${LFS_SOURCES_DIR:?Variável LFS_SOURCES_DIR não definida}"

PKG_NAME="binutils"
PKG_VER="2.45.1"
PKG_DIR="${PKG_NAME}-${PKG_VER}"
TARBALL="${PKG_DIR}.tar.xz"
URL="https://ftp.gnu.org/gnu/binutils/${TARBALL}"

# Preencha aqui se quiser checagem real de MD5:
TARBALL_MD5=""

SRC_DIR="${LFS_SOURCES_DIR}"
PKG_SRC_DIR="${SRC_DIR}/${PKG_DIR}"

# Diretório onde o pacote binário final será salvo:
BIN_PKG_DIR="${ADM_BIN_PKG_DIR:-${LFS}/binary-packages}"

log()   { echo "==> [${PKG_NAME}] $*"; }
error() { echo "ERRO [${PKG_NAME}]: $*" >&2; exit 1; }

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

    [[ -n "${TARBALL_MD5}" ]] || {
        log "MD5 não definido (TARBALL_MD5 vazio); pulando verificação de integridade."
        return 0
    }

    if ! command -v md5sum >/dev/null 2>&1; then
        log "md5sum não encontrado; não será feita verificação de integridade."
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

build_and_package() {
    ensure_source_dir

    cd "${PKG_SRC_DIR}"

    # Diretório de build separado (padrão moderno do LFS)
    rm -rf build
    mkdir -v build
    cd build

    # Configuração final do LFS 12.4 (capítulo 8, Binutils)
    # Exemplo típico:
    #   ../configure --prefix=/usr \
    #                --build=$(../config.guess) \
    #                --enable-gold \
    #                --enable-ld=default \
    #                --enable-plugins \
    #                --enable-shared \
    #                --disable-werror \
    #                --enable-64-bit-bfd \
    #                --with-system-zlib
    log "Configurando Binutils-${PKG_VER} ..."
    ../configure \
        --prefix=/usr \
        --build="$(../config.guess)" \
        --enable-gold \
        --enable-ld=default \
        --enable-plugins \
        --enable-shared \
        --disable-werror \
        --enable-64-bit-bfd \
        --with-system-zlib

    log "Compilando ..."
    make

    # Aqui entra uma diferença importante:
    # Em vez de instalar direto em /usr, usamos DESTDIR para criar
    # uma árvore temporária que virará o pacote binário.
    local destdir
    destdir="$(pwd)/pkgdest"     # árvore temporária do pacote
    rm -rf "${destdir}"
    mkdir -p "${destdir}"

    log "Instalando em DESTDIR=${destdir} ..."
    make DESTDIR="${destdir}" install

    # Alguns passos do LFS usam comandos adicionais após install.
    # Tipicamente, para binutils final, há ajustes em ld/ ou symlinks;
    # se forem necessários, você aplica aqui dentro do DESTDIR.
    # Exemplo (ajuste opcional de ld se estiver no livro):
    #   make -C ld clean
    #   make -C ld LIB_PATH=/usr/lib:/lib
    #   cp -v ld/ld-new /usr/bin
    #
    # Adaptando para DESTDIR:
    #   make -C ld clean
    #   make -C ld LIB_PATH=/usr/lib:/lib
    #   install -v ld/ld-new "${destdir}/usr/bin/ld"
    #
    # Ajuste aqui conforme sua edição do livro:

    log "Executando ajustes pós-instalação (ld refinado) ..."
    make -C ld clean
    make -C ld LIB_PATH=/usr/lib:/lib
    install -v ld/ld-new "${destdir}/usr/bin/ld"

    # Opcional: strip de binários dentro do DESTDIR para reduzir tamanho
    if command -v strip >/dev/null 2>&1; then
        log "Executando strip em binários e libs dentro de ${destdir} ..."
        find "${destdir}/usr" -type f -name '*.a'   -exec strip --strip-debug '{}' \; 2>/dev/null || true
        find "${destdir}/usr" -type f -name '*.so*' -exec strip --strip-unneeded '{}' \; 2>/dev/null || true
        find "${destdir}/usr" -type f -perm -u+x    -exec strip --strip-all '{}' \; 2>/dev/null || true
    else
        log "strip não encontrado; pulando etapa de strip."
    fi

    # Agora empacotar em .tar.zst
    mkdir -p "${BIN_PKG_DIR}"

    local pkgfile
    pkgfile="${BIN_PKG_DIR}/${PKG_NAME}-${PKG_VER}-$(uname -m).tar.zst"

    log "Gerando pacote binário ${pkgfile} ..."
    # O conteúdo de destdir representa a raiz (/), então temos que tar a partir dele
    (
        cd "${destdir}"
        # Criar .tar e comprimir com zstd - ou usar tar + --zstd se disponível
        if tar --help 2>/dev/null | grep -q -- '--zstd'; then
            tar --zstd -cf "${pkgfile}" .
        else
            # fallback: tar normal + zstd
            local tmp_tar="${pkgfile%.zst}.tar"
            tar -cf "${tmp_tar}" .
            zstd -f "${tmp_tar}" -o "${pkgfile}"
            rm -f "${tmp_tar}"
        fi
    )

    log "Pacote binário criado em: ${pkgfile}"
    log "Binutils-${PKG_VER} (fonte) construído e empacotado com sucesso."
}

main() {
    log "Iniciando build de ${PKG_NAME}-${PKG_VER} com empacotamento binário (.tar.zst)"
    log "LFS             = ${LFS}"
    log "LFS_SOURCES_DIR = ${LFS_SOURCES_DIR}"
    log "BIN_PKG_DIR     = ${BIN_PKG_DIR}"

    build_and_package

    log "Concluído."
}

main "$@"
