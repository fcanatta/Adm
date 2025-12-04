#!/usr/bin/env bash
# Build script para GCC-15.2.0 - Pass 1 (LFS-style) integrado ao adm

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
#  ADM_PKG_NAME   -> ex: gcc-pass1
#  ADM_LIBC       -> glibc|musl
#  ADM_ROOTFS     -> rootfs alvo (vamos tratar como $LFS)
#  ADM_CACHE_SRC  -> cache de sources
#  ADM_CACHE_PKG  -> cache de tarballs
#  ADM_BUILDINFO  -> arquivo onde o adm espera o buildinfo

PKG_NAME="${ADM_PKG_NAME:-gcc-pass1}"

GCC_VER="15.2.0"
PKG_VERSION="${GCC_VER}-pass1"

# Versões auxiliares (ajuste se quiser outras)
MPFR_VER="4.2.1"
GMP_VER="6.3.0"
MPC_VER="1.3.1"

# URLs (ajuste para mirrors locais se quiser)
GCC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz"
MPFR_URL="https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VER}.tar.xz"
GMP_URL="https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz"
MPC_URL="https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VER}.tar.gz"

# MD5 opcionais (deixe vazio por enquanto ou preencha depois)
GCC_MD5=""
MPFR_MD5=""
GMP_MD5=""
MPC_MD5=""

SRC_GCC="${ADM_CACHE_SRC}/gcc-${GCC_VER}.tar.xz"
SRC_MPFR="${ADM_CACHE_SRC}/mpfr-${MPFR_VER}.tar.xz"
SRC_GMP="${ADM_CACHE_SRC}/gmp-${GMP_VER}.tar.xz"
SRC_MPC="${ADM_CACHE_SRC}/mpc-${MPC_VER}.tar.gz"

BUILD_DIR="/tmp/adm-build-${PKG_NAME}-${ADM_LIBC:-unknown}"
DESTDIR="${BUILD_DIR}/destdir"
SRC_DIR="${BUILD_DIR}/gcc-${GCC_VER}"

log()     { printf "[%s] %s\n" "$(date +'%H:%M:%S')" "$*"; }
log_err() { printf "[%s] [ERRO] %s\n" "$(date +'%H:%M:%S')" "$*" >&2; }

download_one() {
    local url="$1" dst="$2" md5="$3" name="$4"

    mkdir -p "$(dirname "$dst")"

    if [ -f "$dst" ]; then
        log "Usando ${name} em cache: $dst"
    else
        log "Baixando ${name} de ${url}..."
        if command -v curl >/dev/null 2>&1; then
            curl -L -o "$dst" "$url"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "$dst" "$url"
        else
            log_err "Nem curl nem wget encontrados para baixar ${name}."
            exit 1
        fi
    fi

    if [ -n "$md5" ]; then
        log "Verificando MD5 de ${name}..."
        echo "${md5}  ${dst}" | md5sum -c - || {
            log_err "Falha na verificação de MD5 de ${dst}"
            exit 1
        }
    else
        log "MD5 de ${name} não definido, pulando verificação (preencha depois se quiser)."
    fi
}

download_sources() {
    download_one "$GCC_URL"  "$SRC_GCC"  "$GCC_MD5"  "GCC-${GCC_VER}"
    download_one "$MPFR_URL" "$SRC_MPFR" "$MPFR_MD5" "MPFR-${MPFR_VER}"
    download_one "$GMP_URL"  "$SRC_GMP"  "$GMP_MD5"  "GMP-${GMP_VER}"
    download_one "$MPC_URL"  "$SRC_MPC"  "$MPC_MD5"  "MPC-${MPC_VER}"
}

prepare_builddir() {
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR" "$DESTDIR"

    log "Extraindo GCC ${GCC_VER} para ${BUILD_DIR}..."
    tar -xf "$SRC_GCC" -C "$BUILD_DIR"

    if [ ! -d "$SRC_DIR" ]; then
        log_err "Diretório de source esperado não encontrado: $SRC_DIR"
        exit 1
    fi

    cd "$SRC_DIR"

    # MPFR, GMP e MPC dentro da árvore do GCC (modelo LFS)
    log "Incorporando MPFR-${MPFR_VER}, GMP-${GMP_VER} e MPC-${MPC_VER} na árvore do GCC..."

    tar -xf "$SRC_MPFR" -C "$SRC_DIR"
    mv -v "mpfr-${MPFR_VER}" mpfr

    tar -xf "$SRC_GMP" -C "$SRC_DIR"
    mv -v "gmp-${GMP_VER}" gmp

    tar -xf "$SRC_MPC" -C "$SRC_DIR"
    mv -v "mpc-${MPC_VER}" mpc

    # Diretório de build separado
    mkdir -pv "${SRC_DIR}/build"
    cd "${SRC_DIR}/build"
}

do_build() {
    # LFS_TGT padrão se não vier de fora
    export LFS_TGT="${LFS_TGT:-"$(uname -m)-lfs-linux-gnu"}"

    # ADM_ROOTFS será tratado como $LFS
    if [ -z "${ADM_ROOTFS:-}" ]; then
        log_err "ADM_ROOTFS não definido pelo adm (rootfs alvo)."
        exit 1
    fi
    export LFS="$ADM_ROOTFS"

    log "Iniciando configuração do GCC ${GCC_VER} - Pass 1"
    log "  LFS (sysroot)   = ${LFS}"
    log "  LFS_TGT         = ${LFS_TGT}"
    log "  prefix (no alvo)= /tools"
    log "  DESTDIR         = ${DESTDIR}"

    # Profile de libc (glibc/musl) já foi carregado pelo adm
    # então CC, CFLAGS, LDFLAGS etc já estão no ambiente.

    ../configure \
        --target="${LFS_TGT}" \
        --prefix=/tools \
        --with-sysroot="${LFS}" \
        --with-newlib \
        --without-headers \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-decimal-float \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdcxx \
        --enable-languages=c,c++ \
        --enable-default-pie \
        --enable-default-ssp

    log "Rodando make (isso pode demorar um pouco)..."
    make

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
        # Conteúdo relativo (.) → /tools/... dentro do ROOTFS quando o adm instalar
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
        download_sources
        prepare_builddir
        do_build
        strip_and_package
        ;;
    *)
        log_err "Ação inválida: $ACTION"
        exit 1
        ;;
esac
