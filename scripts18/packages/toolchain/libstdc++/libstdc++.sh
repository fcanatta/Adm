#!/usr/bin/env bash
# Build Libstdc++ from GCC-15.2.0 (LFS r12.4) para o adm
set -euo pipefail

# Ambiente básico exigido
: "${LFS:?Variável LFS não definida}"
: "${LFS_SOURCES_DIR:?Variável LFS_SOURCES_DIR não definida}"
: "${LFS_TGT:?Variável LFS_TGT não definida}"

GCC_VERSION=15.2.0
GCC_TARBALL="gcc-${GCC_VERSION}.tar.xz"
GCC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/${GCC_TARBALL}"
# MD5 oficial do tarball gcc-15.2.0.tar.xz (LFS/BLFS)
GCC_MD5="b861b092bf1af683c46a8aa2e689a6fd"

GCC_SRC_DIR="${LFS_SOURCES_DIR}/gcc-${GCC_VERSION}"
TARBALL_PATH="${LFS_SOURCES_DIR}/${GCC_TARBALL}"

log() {
    echo "==> [libstdc++] $*"
}

error() {
    echo "ERRO [libstdc++]: $*" >&2
    exit 1
}

fetch_tarball() {
    mkdir -p "${LFS_SOURCES_DIR}"

    if [[ -f "${TARBALL_PATH}" ]]; then
        log "Tarball já existe: ${TARBALL_PATH}"
        return 0
    fi

    log "Baixando ${GCC_TARBALL} de ${GCC_URL} ..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL -o "${TARBALL_PATH}" "${GCC_URL}" \
            || error "Falha ao baixar ${GCC_URL} com curl"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${TARBALL_PATH}" "${GCC_URL}" \
            || error "Falha ao baixar ${GCC_URL} com wget"
    else
        error "Nem curl nem wget encontrados para baixar o tarball."
    fi
}

check_md5() {
    if ! command -v md5sum >/dev/null 2>&1; then
        log "md5sum não encontrado, **NÃO** será possível verificar integridade. (use por sua conta e risco)"
        return 0
    fi

    log "Verificando MD5 de ${TARBALL_PATH} ..."
    local expected actual
    expected="${GCC_MD5}"
    # md5sum imprime "hash  arquivo"
    actual="$(md5sum "${TARBALL_PATH}" | awk '{print $1}')"

    if [[ "${actual}" != "${expected}" ]]; then
        error "MD5 incorreto para ${TARBALL_PATH}.
  Esperado: ${expected}
  Obtido..: ${actual}
Apague o tarball e tente novamente."
    fi

    log "MD5 OK (${actual})"
}

ensure_sources_dir() {
    if [[ ! -d "${GCC_SRC_DIR}" ]]; then
        log "Diretório de fontes ${GCC_SRC_DIR} não existe; tentando extrair tarball..."
        fetch_tarball
        check_md5
        tar -xf "${TARBALL_PATH}" -C "${LFS_SOURCES_DIR}"
    fi

    if [[ ! -d "${GCC_SRC_DIR}" ]]; then
        error "Diretório ${GCC_SRC_DIR} ainda não existe após tentativa de extração."
    fi
}

strip_libs() {
    log "Iniciando etapa de strip das libs libstdc++ em ${LFS}/usr/lib ..."

    local target_strip=""
    # 1) primeiro tenta o strip do toolchain alvo dentro de $LFS/tools
    if [[ -x "${LFS}/tools/bin/${LFS_TGT}-strip" ]]; then
        target_strip="${LFS}/tools/bin/${LFS_TGT}-strip"
    # 2) depois tenta ${LFS_TGT}-strip no PATH
    elif command -v "${LFS_TGT}-strip" >/dev/null 2>&1; then
        target_strip="$(command -v "${LFS_TGT}-strip")"
    # 3) por último, strip do host (menos ideal, mas atende ao pedido)
    elif command -v strip >/dev/null 2>&1; then
        target_strip="strip"
        log "Aviso: usando strip do host (${target_strip})."
    else
        log "strip não encontrado; pulando etapa de strip."
        return 0
    fi

    log "Usando strip: ${target_strip}"

    local libs=()
    # Procura libs relevantes em $LFS/usr/lib (nível raiz)
    while IFS= read -r f; do
        libs+=("$f")
    done < <(
        find "${LFS}/usr/lib" -maxdepth 1 -type f \
            \( -name 'libstdc++*.so*' \
               -o -name 'libsupc++*.so*' \
               -o -name 'libstdc++*.a' \
               -o -name 'libsupc++*.a' \) 2>/dev/null || true
    )

    if [[ ${#libs[@]} -eq 0 ]]; then
        log "Nenhuma lib libstdc++/*supc++ encontrada para strip em ${LFS}/usr/lib."
        return 0
    fi

    local lib
    for lib in "${libs[@]}"; do
        log "Strip em ${lib}"
        # --strip-unneeded é seguro para .so; para .a geralmente também
        if ! "${target_strip}" --strip-unneeded "${lib}" 2>/dev/null; then
            log "Aviso: falha ao dar strip em ${lib} (ignorando)."
        fi
    done

    log "Strip das libs libstdc++ concluído."
}

main() {
    log "Iniciando build do Libstdc++ a partir do GCC-${GCC_VERSION}"
    log "LFS             = ${LFS}"
    log "LFS_SOURCES_DIR = ${LFS_SOURCES_DIR}"
    log "LFS_TGT         = ${LFS_TGT}"
    log "GCC_SRC_DIR     = ${GCC_SRC_DIR}"

    ensure_sources_dir

    cd "${GCC_SRC_DIR}"

    # Diretório de build limpo
    rm -rf build
    mkdir -v build
    cd build

    log "Configurando libstdc++ (conforme LFS r12.4 - libstdc++ cross)..."

    ../libstdc++-v3/configure      \
        --host="${LFS_TGT}"        \
        --build="$("../config.guess")" \
        --prefix=/usr              \
        --disable-multilib         \
        --disable-nls              \
        --disable-libstdcxx-pch    \
        --with-gxx-include-dir="/tools/${LFS_TGT}/include/c++/${GCC_VERSION}"

    log "Compilando libstdc++ ..."
    make

    log "Instalando em DESTDIR=${LFS} ..."
    make DESTDIR="${LFS}" install

    log "Removendo arquivos .la desnecessários ..."
    rm -v "${LFS}"/usr/lib/lib{stdc++{,exp,fs},supc++}.la 2>/dev/null || true

    # Etapa extra pedida: strip
    strip_libs

    log "Build e instalação do Libstdc++ concluídos com sucesso."
}

main "$@"
