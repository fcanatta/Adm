#!/usr/bin/env bash
set -euo pipefail

#============================================================
#  Binutils - Pass 1 (Cross Binutils para LFS)
#  Baixa, verifica MD5, constrói, instala via DESTDIR
#  e empacota em tar.zst
#============================================================

#------------------------------------------------------------
# Verificações básicas
#------------------------------------------------------------

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "ERRO: não execute este script como root. Use o usuário de build (ex: 'lfs')." >&2
    exit 1
fi

: "${LFS:?Variável LFS não definida (ex: /mnt/lfs)}"
: "${LFS_TGT:?Variável LFS_TGT não definida (ex: x86_64-lfs-linux-gnu)}"

#------------------------------------------------------------
# Configuração do pacote / caminhos
#------------------------------------------------------------

PKG_NAME="binutils-pass1"
BINUTILS_VERSION="${BINUTILS_VERSION:-2.41}"

# URL oficial (pode sobrescrever com SRC_URL)
SRC_URL="${SRC_URL:-https://sourceware.org/pub/binutils/releases/binutils-${BINUTILS_VERSION}.tar.xz}"

# MD5 oficial do LFS 12.0 para binutils-2.41.tar.xz
SRC_MD5="${SRC_MD5:-256d7e0ad998e423030c84483a7c1e30}"

SRC_DIR="${SRC_DIR:-$LFS/sources}"
TARBALL="binutils-${BINUTILS_VERSION}.tar.xz"
PKG_DIR="binutils-${BINUTILS_VERSION}"

# DESTDIR para instalação “fake root” do pacote
DESTDIR="${DESTDIR:-$LFS/pkg/${PKG_NAME}}"

# Diretório onde o pacote .tar.zst será salvo
PKG_OUTPUT_DIR="${PKG_OUTPUT_DIR:-$LFS/packages}"
PKG_ARCH="${PKG_ARCH:-$(uname -m)}"
PKG_TARBALL="${PKG_TARBALL:-$PKG_OUTPUT_DIR/${PKG_NAME}-${BINUTILS_VERSION}-${PKG_ARCH}.tar.zst}"

# Número de jobs de compilação
if command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc)"
else
    JOBS=1
fi

#------------------------------------------------------------
# Funções auxiliares
#------------------------------------------------------------

log() {
    echo "[$(date +'%F %T')] $*"
}

die() {
    echo "ERRO: $*" >&2
    exit 1
}

download_source() {
    mkdir -p "$SRC_DIR"
    cd "$SRC_DIR"

    if [[ -f "$TARBALL" ]]; then
        log "Tarball já existe: $SRC_DIR/$TARBALL"
    else
        log "Baixando $SRC_URL ..."
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
        log "md5sum não encontrado; pulando verificação de MD5."
        return 0
    fi

    log "Verificando MD5 de $TARBALL ..."
    echo "${SRC_MD5}  ${TARBALL}" | md5sum -c - || die "MD5 incorreto para $TARBALL"
    log "MD5 OK."
}

prepare_destdirs() {
    mkdir -p "$DESTDIR"
    mkdir -p "$PKG_OUTPUT_DIR"
}

#------------------------------------------------------------
# Build / Install / Package
#------------------------------------------------------------

main() {
    log "Iniciando build do Binutils Pass 1 (versão $BINUTILS_VERSION)"
    log "LFS=$LFS"
    log "LFS_TGT=$LFS_TGT"
    log "JOBS=$JOBS"
    log "SRC_DIR=$SRC_DIR"
    log "DESTDIR=$DESTDIR"
    log "Pacote final: $PKG_TARBALL"

    download_source
    check_md5
    prepare_destdirs

    [[ -d "$LFS/tools" ]] || mkdir -p "$LFS/tools"

    cd "$SRC_DIR"

    # Limpa build anterior, se houver
    log "Removendo diretório de build anterior (se existir): $PKG_DIR"
    rm -rf "$PKG_DIR"

    log "Extraindo tarball: $TARBALL"
    tar -xf "$TARBALL"

    cd "$PKG_DIR"
    log "Criando diretório de build separado"
    mkdir -v build
    cd build

    # IMPORTANTE: usamos prefix=/tools e DESTDIR para instalar em árvore fake
    log "Rodando configure (cross binutils Pass 1)..."
    ../configure \
        --prefix=/tools \
        --with-sysroot="$LFS" \
        --target="$LFS_TGT"   \
        --disable-nls         \
        --enable-gprofng=no   \
        --disable-werror

    log "Compilando Binutils (make -j$JOBS)..."
    make -j"$JOBS"

    #----------------------------------------
    # Instala em DESTDIR (árvore fake)
    #----------------------------------------
    log "Instalando em DESTDIR: $DESTDIR ..."
    rm -rf "$DESTDIR"
    make DESTDIR="$DESTDIR" install

    # Agora copiamos do DESTDIR para o LFS real
    # Dentro do DESTDIR a instalação foi para /tools, então copiamos DESTDIR/tools -> $LFS/tools
    if [[ -d "$DESTDIR/tools" ]]; then
        log "Copiando de DESTDIR/tools para $LFS/tools ..."
        mkdir -p "$LFS/tools"
        cp -av "$DESTDIR/tools/." "$LFS/tools/"
    else
        die "DESTDIR/tools não encontrado após instalação."
    fi

    #----------------------------------------
    # Empacotamento em tar.zst
    #----------------------------------------
    log "Empacotando DESTDIR em $PKG_TARBALL ..."
    cd "$DESTDIR"
    if ! command -v zstd >/dev/null 2>&1; then
        die "zstd não encontrado; não é possível gerar tar.zst."
    fi
    # Cria tarball comprimido (conteúdo relativo à raiz do DESTDIR)
    tar -cf - . | zstd -z -q -o "$PKG_TARBALL"
    log "Pacote gerado: $PKG_TARBALL"

    #----------------------------------------
    # Limpeza opcional do source
    #----------------------------------------
    cd "$SRC_DIR"
    log "Limpando diretório de build: removendo $PKG_DIR"
    rm -rf "$PKG_DIR"

    log "Binutils Pass 1 concluído com sucesso."
}

main "$@"
