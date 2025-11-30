#!/usr/bin/env bash
set -euo pipefail

#============================================================
#  Binutils - Pass 1 (Cross Binutils para LFS)
#  - Define ambiente cross-toolchain
#  - Baixa e verifica MD5 do source
#  - Constrói Binutils Pass 1
#  - Instala em DESTDIR
#  - Faz strip seguro nos binários do DESTDIR
#  - Copia para $LFS/tools
#  - Empacota em tar.zst
#============================================================

#------------------------------------------------------------
# Ambiente e triplets
#------------------------------------------------------------

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "ERRO: não execute este script como root." >&2
    exit 1
fi

: "${LFS:?Variável LFS não definida (ex: /mnt/lfs)}"

# Triplets host/target
LFS_HOST="$(uname -m)-pc-linux-gnu"
LFS_TGT="${LFS_TGT:-$(uname -m)-lfs-linux-gnu}"

export LFS
export LFS_HOST
export LFS_TGT

# PATH da toolchain temporária
export PATH="$LFS/tools/bin:/usr/bin:/bin"

# Evitar poluição do host
unset CC CXX CPP LD AR AS NM STRIP RANLIB OBJDUMP OBJCOPY

#------------------------------------------------------------
# Configuração de versões e caminhos
#------------------------------------------------------------

PKG_NAME="binutils-pass1"

BINUTILS_VERSION="${BINUTILS_VERSION:-2.41}"

SRC_URL="${SRC_URL:-https://sourceware.org/pub/binutils/releases/binutils-${BINUTILS_VERSION}.tar.xz}"

# MD5 oficial do binutils-2.41 (LFS 12.x)
SRC_MD5="${SRC_MD5:-256d7e0ad998e423030c84483a7c1e30}"

SRC_DIR="${SRC_DIR:-$LFS/sources}"
TARBALL="binutils-${BINUTILS_VERSION}.tar.xz"
PKG_DIR="binutils-${BINUTILS_VERSION}"

# DESTDIR para fake root do pacote
DESTDIR="${DESTDIR:-$LFS/pkg/${PKG_NAME}}"

# Diretório de saída do pacote
PKG_OUTPUT_DIR="${PKG_OUTPUT_DIR:-$LFS/packages}"
PKG_ARCH="${PKG_ARCH:-$(uname -m)}"
PKG_TARBALL="$PKG_OUTPUT_DIR/${PKG_NAME}-${BINUTILS_VERSION}-${PKG_ARCH}.tar.zst"

# Número de jobs
if command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc)"
else
    JOBS=1
fi

#------------------------------------------------------------
# Funções auxiliares
#------------------------------------------------------------

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
        if command -v wget >/dev/null 2>&1; then
            wget -c "$SRC_URL" -O "$TARBALL"
        elif command -v curl >/dev/null 2>&1; then
            curl -L "$SRC_URL" -o "$TARBALL"
        else
            die "Nem wget nem curl encontrados para baixar o source."
        fi
    fi
}

check_md5() {
    cd "$SRC_DIR"
    if ! command -v md5sum >/dev/null 2>&1; then
        msg "md5sum não encontrado; ignorando verificação de MD5."
        return 0
    fi

    msg "Verificando MD5 de $TARBALL ..."
    echo "${SRC_MD5}  ${TARBALL}" | md5sum -c - || die "MD5 incorreto para $TARBALL"
    msg "MD5 OK."
}

prepare_destdirs() {
    mkdir -p "$DESTDIR"
    mkdir -p "$PKG_OUTPUT_DIR"
    mkdir -p "$LFS/tools"
}

#------------------------------------------------------------
# Strip seguro para Binutils Pass 1 (no DESTDIR)
#------------------------------------------------------------

strip_binutils_pass1() {
    msg "Executando strip seguro dos binários do Binutils Pass 1 (DESTDIR=$DESTDIR)..."

    local HOST_STRIP
    if command -v strip >/dev/null 2>&1; then
        HOST_STRIP="strip"
    else
        die "strip não encontrado no sistema host."
    fi

    # Diretórios dentro do DESTDIR a serem verificados
    local STRIP_DIRS=(
        "$DESTDIR/tools/bin"
        "$DESTDIR/tools/$LFS_TGT/bin"
        "$DESTDIR/tools/lib"
        "$DESTDIR/tools/lib64"
    )

    local d
    for d in "${STRIP_DIRS[@]}"; do
        [[ -d "$d" ]] || continue

        msg "Strip em: $d"
        # Só arquivos ELF
        while IFS= read -r f; do
            if file "$f" | grep -q "ELF"; then
                $HOST_STRIP --strip-unneeded "$f" || true
            fi
        done < <(find "$d" -type f -print)
    done

    msg "Strip concluído para Binutils Pass 1."
}

#------------------------------------------------------------
# Build / Install / Package
#------------------------------------------------------------

main() {
    msg "==== Binutils ${BINUTILS_VERSION} - Pass 1 ===="
    msg "LFS        = $LFS"
    msg "HOST       = $LFS_HOST"
    msg "TARGET     = $LFS_TGT"
    msg "PATH       = $PATH"
    msg "DESTDIR    = $DESTDIR"
    msg "PKG_TAR    = $PKG_TARBALL"

    download_source
    check_md5
    prepare_destdirs

    cd "$SRC_DIR"

    # Limpa build anterior
    msg "Removendo diretório de build antigo (se existir): $PKG_DIR"
    rm -rf "$PKG_DIR"

    msg "Extraindo tarball: $TARBALL"
    tar -xf "$TARBALL"

    cd "$PKG_DIR"
    msg "Criando diretório de build separado"
    mkdir -v build
    cd build

    msg "Configurando Binutils (Pass 1) para TARGET $LFS_TGT ..."
    ../configure \
        --prefix=/tools \
        --with-sysroot="$LFS" \
        --target="$LFS_TGT"   \
        --disable-nls         \
        --enable-gprofng=no   \
        --disable-werror

    msg "Compilando Binutils (make -j$JOBS)..."
    make -j"$JOBS"

    msg "Instalando em DESTDIR: $DESTDIR ..."
    rm -rf "$DESTDIR"
    make DESTDIR="$DESTDIR" install

    # Strip no DESTDIR
    strip_binutils_pass1

    # Copiar do DESTDIR para o $LFS/tools real
    msg "Copiando de DESTDIR/tools para $LFS/tools ..."
    if [[ -d "$DESTDIR/tools" ]]; then
        cp -av "$DESTDIR/tools/." "$LFS/tools/"
    else
        die "DESTDIR/tools não encontrado após instalação."
    fi

    # Empacotar o DESTDIR em tar.zst
    msg "Empacotando DESTDIR em $PKG_TARBALL ..."
    cd "$DESTDIR"
    if ! command -v zstd >/dev/null 2>&1; then
        die "zstd não encontrado; não é possível gerar tar.zst."
    fi
    tar -cf - . | zstd -z -q -o "$PKG_TARBALL"

    # Limpar árvore de source
    cd "$SRC_DIR"
    msg "Limpando diretório de build: removendo $PKG_DIR"
    rm -rf "$PKG_DIR"

    msg "==== Binutils ${BINUTILS_VERSION} - Pass 1 concluído com sucesso ===="
}

main "$@"
