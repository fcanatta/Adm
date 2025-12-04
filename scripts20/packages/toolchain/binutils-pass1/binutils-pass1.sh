#!/usr/bin/env bash
# Build script para Binutils-2.45.1 - Pass 1 (LFS-style) integrado ao adm

set -euo pipefail

ACTION="${1:-}"
LIBC="${2:-}"

if [ -z "$ACTION" ]; then
    echo "Uso: $0 build <glibc|musl>" >&2
    exit 1
fi

if [ "$ACTION" != "build" ]; then
    echo "Ação inválida: $ACTION (somente 'build' é suportado)" >&2
    exit 1
fi

# Variáveis que o adm exporta:
#  ADM_CATEGORY   -> ex: toolchain
#  ADM_PKG_NAME   -> ex: binutils-pass1
#  ADM_LIBC       -> glibc|musl
#  ADM_ROOTFS     -> rootfs alvo (vamos tratar como \$LFS)
#  ADM_CACHE_SRC  -> cache de sources
#  ADM_CACHE_PKG  -> cache de tarballs
#  ADM_BUILDINFO  -> arquivo onde o adm espera o buildinfo

PKG_NAME="${ADM_PKG_NAME:-binutils-pass1}"
BINUTILS_VER="2.45.1"
PKG_VERSION="${BINUTILS_VER}-pass1"

# URL oficial (você pode trocar por mirror brasileiro, se quiser)
PKG_SOURCE_URL="https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz"

# Deixe vazio para pular checagem, ou preencha depois com o MD5 real:
# Exemplo de formato: PKG_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
PKG_MD5=""

SRC_ARCHIVE="${ADM_CACHE_SRC}/binutils-${BINUTILS_VER}.tar.xz"
BUILD_DIR="/tmp/adm-build-${PKG_NAME}-${ADM_LIBC:-unknown}"
DESTDIR="${BUILD_DIR}/destdir"
SRC_DIR="${BUILD_DIR}/binutils-${BINUTILS_VER}"

log()  { printf "[%s] %s\n" "$(date +'%H:%M:%S')" "$*"; }
log_err() { printf "[%s] [ERRO] %s\n" "$(date +'%H:%M:%S')" "$*" >&2; }

download_source() {
    mkdir -p "$ADM_CACHE_SRC"

    if [ -f "$SRC_ARCHIVE" ]; then
        log "Usando source em cache: $SRC_ARCHIVE"
    else
        log "Baixando Binutils ${BINUTILS_VER} de ${PKG_SOURCE_URL}..."
        if command -v curl >/dev/null 2>&1; then
            curl -L -o "$SRC_ARCHIVE" "$PKG_SOURCE_URL"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "$SRC_ARCHIVE" "$PKG_SOURCE_URL"
        else
            log_err "Nem curl nem wget encontrados."
            exit 1
        fi
    fi

    if [ -n "$PKG_MD5" ]; then
        log "Verificando MD5..."
        echo "${PKG_MD5}  ${SRC_ARCHIVE}" | md5sum -c - || {
            log_err "Falha na verificação de MD5 de ${SRC_ARCHIVE}"
            exit 1
        }
    else
        log "PKG_MD5 vazio, pulando verificação de checksum (preencha depois se quiser)."
    fi
}

prepare_builddir() {
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR" "$DESTDIR"

    log "Extraindo ${SRC_ARCHIVE} para ${BUILD_DIR}..."
    tar -xf "$SRC_ARCHIVE" -C "$BUILD_DIR"

    if [ ! -d "$SRC_DIR" ]; then
        log_err "Diretório de source esperado não encontrado: $SRC_DIR"
        exit 1
    fi

    cd "$SRC_DIR"
    mkdir -pv build
    cd build
}

do_build() {
    # Em LFS, LFS_TGT geralmente é algo como: x86_64-lfs-linux-gnu
    # Se não estiver definido, tentamos gerar um padrão.
    export LFS_TGT="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"

    # Tratamos ADM_ROOTFS como se fosse $LFS
    if [ -z "${ADM_ROOTFS:-}" ]; then
        log_err "ADM_ROOTFS não definido pelo adm (rootfs alvo)."
        exit 1
    fi
    export LFS="$ADM_ROOTFS"

    log "Iniciando configuração do Binutils ${BINUTILS_VER} - Pass 1"
    log "  LFS (sysroot)   = ${LFS}"
    log "  LFS_TGT         = ${LFS_TGT}"
    log "  prefix (no alvo)= /tools"
    log "  DESTDIR         = ${DESTDIR}"

    # Profile de libc já deve estar carregado pelo adm (glibc/musl),
    # então CC/CFLAGS/LDFLAGS etc já estarão setados.

    ../configure \
        --prefix=/tools \
        --with-sysroot="${LFS}" \
        --target="${LFS_TGT}" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror \
        --enable-new-dtags \
        --enable-default-hash-style=gnu

    log "Rodando make (isso pode demorar um pouco)..."
    make

    # Instalamos em DESTDIR. Isso resulta em:
    #   ${DESTDIR}/tools/...
    # e depois o adm instala isso no rootfs real via tarball.
    log "Instalando no DESTDIR (${DESTDIR})..."
    make DESTDIR="${DESTDIR}" install
}

strip_and_package() {
    log "Fazendo strip de binários ELF em ${DESTDIR}..."
    if command -v strip >/dev/null 2>&1; then
        find "${DESTDIR}" -type f -perm -u+x -exec sh -c '
            for f in "$@"; do
                if file "$f" 2>/dev/null | grep -qi "ELF"; then
                    strip --strip-unneeded "$f" 2>/dev/null || true
                fi
            done
        ' _ {} +
    else
        log "strip não encontrado, pulando etapa de strip."
    fi

    mkdir -p "$ADM_CACHE_PKG"
    local tarball="${ADM_CACHE_PKG}/${PKG_NAME}-${PKG_VERSION}-${ADM_LIBC:-nolibc}.tar.zst"

    log "Gerando tarball otimizado: ${tarball}"
    (
        cd "${DESTDIR}"
        # Conteúdo relativo (.) -> ao extrair no rootfs, teremos /tools/...
        tar -I "zstd -19 --long=31" -cf "${tarball}" .
    )

    log "Gravando buildinfo em ${ADM_BUILDINFO}..."
    cat > "${ADM_BUILDINFO}" <<EOF
PKG_ID="${ADM_CATEGORY}/${PKG_NAME}"
PKG_NAME="${PKG_NAME}"
PKG_CATEGORY="${ADM_CATEGORY}"
PKG_VERSION="${PKG_VERSION}"
PKG_LIBC="${ADM_LIBC}"
PKG_TARBALL="${tarball}"
EOF

    log "Build do ${PKG_NAME} (${PKG_VERSION}) concluído."
    log "  Tarball: ${tarball}"
}

case "$ACTION" in
    build)
        download_source
        prepare_builddir
        do_build
        strip_and_package
        ;;
    *)
        log_err "Ação inválida: $ACTION"
        exit 1
        ;;
esac
