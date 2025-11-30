#!/usr/bin/env bash
set -euo pipefail

#============================================================
#  Binutils - Pass 1 (Cross Binutils para LFS)
#  - Define ambiente cross-toolchain corretamente
#  - Baixa e verifica MD5
#  - Constrói com target triplet
#  - Instala via DESTDIR
#  - Empacota como tar.zst
#============================================================

#------------------------------------------------------------
# Verificações de ambiente e triplet
#------------------------------------------------------------

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "ERRO: não execute este script como root." >&2
    exit 1
fi

# Caminho base do LFS
: "${LFS:?Variável LFS não definida (ex: /mnt/lfs)}"

# O triplet HOST é o sistema que está executando a construção
LFS_HOST="$(uname -m)-pc-linux-gnu"

# O triplet TARGET é o sistema que estamos construindo
# O livro LFS recomenda explicitamente esse formato:
#   x86_64-lfs-linux-gnu
LFS_TGT="${LFS_TGT:-$(uname -m)-lfs-linux-gnu}"

export LFS
export LFS_HOST
export LFS_TGT

# Ajuste indispensável do PATH (como no LFS Capítulo 4)
export PATH="$LFS/tools/bin:/usr/bin:/bin"

# Não deixar o host poluir a toolchain
unset CC CXX CPP LD AR AS NM STRIP RANLIB OBJDUMP OBJCOPY

#============================================================
# Configuração do pacote
#============================================================

PKG_NAME="binutils-pass1"
BINUTILS_VERSION="${BINUTILS_VERSION:-2.41}"

SRC_URL="${SRC_URL:-https://sourceware.org/pub/binutils/releases/binutils-${BINUTILS_VERSION}.tar.xz}"
SRC_MD5="${SRC_MD5:-256d7e0ad998e423030c84483a7c1e30}"  # hash oficial LFS

SRC_DIR="${SRC_DIR:-$LFS/sources}"
TARBALL="binutils-${BINUTILS_VERSION}.tar.xz"
PKG_DIR="binutils-${BINUTILS_VERSION}"

DESTDIR="${DESTDIR:-$LFS/pkg/${PKG_NAME}}"

PKG_OUTPUT_DIR="${PKG_OUTPUT_DIR:-$LFS/packages}"
PKG_ARCH="${PKG_ARCH:-$(uname -m)}"
PKG_TARBALL="$PKG_OUTPUT_DIR/${PKG_NAME}-${BINUTILS_VERSION}-${PKG_ARCH}.tar.zst"

if command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc)"
else
    JOBS=1
fi

#============================================================
# Funções auxiliares
#============================================================

msg() {
    echo -e "\033[1;34m[$(date +'%F %T')] $*\033[0m"
}

die() {
    echo -e "\033[1;31mERRO: $*\033[0m" >&2
    exit 1
}

download_source() {
    mkdir -p "$SRC_DIR"
    cd "$SRC_DIR"

    if [[ -f "$TARBALL" ]]; then
        msg "Tarball já existe: $SRC_DIR/$TARBALL"
    else
        msg "Baixando $SRC_URL ..."
        if command -v wget >/dev/null; then
            wget -c "$SRC_URL" -O "$TARBALL"
        else
            curl -L "$SRC_URL" -o "$TARBALL"
        fi
    fi
}

check_md5() {
    cd "$SRC_DIR"
    if ! command -v md5sum >/dev/null; then
        msg "md5sum não encontrado; ignorando verificação."
        return
    fi
    msg "Verificando MD5..."
    echo "${SRC_MD5}  ${TARBALL}" | md5sum -c - || die "MD5 inválido!"
}

prepare_destdirs() {
    mkdir -p "$DESTDIR"
    mkdir -p "$PKG_OUTPUT_DIR"
}

#============================================================
# Build
#============================================================

main() {
    msg "==== Binutils Pass 1 ===="
    msg "LFS        = $LFS"
    msg "HOST       = $LFS_HOST"
    msg "TARGET     = $LFS_TGT"
    msg "PATH       = $PATH"
    msg "DESTDIR    = $DESTDIR"
    msg "PKG_TARBAL = $PKG_TARBALL"

    download_source
    check_md5
    prepare_destdirs

    cd "$SRC_DIR"

    msg "Removendo build antigo..."
    rm -rf "$PKG_DIR"

    msg "Extraindo tarball..."
    tar -xf "$TARBALL"

    cd "$PKG_DIR"
    mkdir -v build
    cd build

    msg "Configurando para TARGET $LFS_TGT ..."
    ../configure \
        --prefix=/tools \
        --with-sysroot="$LFS" \
        --target="$LFS_TGT" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror

    msg "Compilando..."
    make -j"$JOBS"

    msg "Instalando em DESTDIR..."
    rm -rf "$DESTDIR"
    make DESTDIR="$DESTDIR" install

    msg "Copiando conteúdo final para $LFS/tools ..."
    mkdir -p "$LFS/tools"
    cp -av "$DESTDIR/tools/." "$LFS/tools/"

    msg "Empacotando tar.zst..."
    cd "$DESTDIR"
    tar -cf - . | zstd -z -q -o "$PKG_TARBALL"

    msg "Limpando diretório temporário..."
    cd "$SRC_DIR"
    rm -rf "$PKG_DIR"

    msg "==== Binutils Pass 1 concluído com sucesso ===="
}

main "$@"
