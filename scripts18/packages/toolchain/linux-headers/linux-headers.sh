#!/usr/bin/env bash
set -euo pipefail

#============================================================
#  Linux-6.17.8 API Headers
#  - Segue LFS 12.4 (seção 5.4) adaptado para DESTDIR
#  - Baixa o kernel, verifica MD5
#  - Gera os headers com make headers
#  - Limpa arquivos não .h
#  - Instala em DESTDIR/usr/include
#  - Copia para $LFS/usr
#  - Empacota em tar.zst
#============================================================

#------------------------------------------------------------
# Ambiente e triplets (para manter padrão com os outros scripts)
#------------------------------------------------------------

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "ERRO: não execute este script como root." >&2
    exit 1
fi

: "${LFS:?Variável LFS não definida (ex: /mnt/lfs)}"

LFS_HOST="$(uname -m)-pc-linux-gnu"
LFS_TGT="${LFS_TGT:-$(uname -m)-lfs-linux-gnu}"

export LFS
export LFS_HOST
export LFS_TGT

# PATH padrão dos scripts temporários
export PATH="$LFS/tools/bin:/usr/bin:/bin"

#------------------------------------------------------------
# Configuração de versões e caminhos
#------------------------------------------------------------

PKG_NAME="linux-headers"

KERNEL_VERSION="${KERNEL_VERSION:-6.17.8}"

# URL e MD5 conforme LFS (All Packages) para linux-6.17.8 2
KERNEL_SRC_URL="${KERNEL_SRC_URL:-https://www.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz}"
KERNEL_MD5="${KERNEL_MD5:-74c34fafb5914d05447863cdc304ab55}"

SRC_DIR="${SRC_DIR:-$LFS/sources}"
TARBALL="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_DIR="linux-${KERNEL_VERSION}"

# DESTDIR para empacotar os headers
DESTDIR="${DESTDIR:-$LFS/pkg/${PKG_NAME}}"

PKG_OUTPUT_DIR="${PKG_OUTPUT_DIR:-$LFS/packages}"
PKG_ARCH="${PKG_ARCH:-$(uname -m)}"
PKG_TARBALL="$PKG_OUTPUT_DIR/${PKG_NAME}-${KERNEL_VERSION}-${PKG_ARCH}.tar.zst"

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

download_and_check_kernel() {
    mkdir -p "$SRC_DIR"
    cd "$SRC_DIR"

    if [[ -f "$TARBALL" ]]; then
        msg "Tarball já existe: $SRC_DIR/$TARBALL"
    else
        msg "Baixando $KERNEL_SRC_URL ..."
        if command -v wget >/dev/null 2>&1; then
            wget -c "$KERNEL_SRC_URL" -O "$TARBALL"
        elif command -v curl >/dev/null 2>&1; then
            curl -L "$KERNEL_SRC_URL" -o "$TARBALL"
        else
            die "Nem wget nem curl encontrados para baixar o kernel."
        fi
    fi

    if command -v md5sum >/dev/null 2>&1; then
        msg "Verificando MD5 de $TARBALL ..."
        echo "${KERNEL_MD5}  ${TARBALL}" | md5sum -c - || die "MD5 incorreto para $TARBALL"
        msg "MD5 OK."
    else
        msg "md5sum não encontrado; **não** foi possível verificar o MD5."
    fi
}

prepare_dirs() {
    mkdir -p "$DESTDIR"
    mkdir -p "$PKG_OUTPUT_DIR"
    mkdir -p "$LFS/usr"
}

#------------------------------------------------------------
# Build / Install / Package
#------------------------------------------------------------

main() {
    msg "==== Linux-${KERNEL_VERSION} API Headers ===="
    msg "LFS        = $LFS"
    msg "HOST       = $LFS_HOST"
    msg "TARGET     = $LFS_TGT"
    msg "PATH       = $PATH"
    msg "DESTDIR    = $DESTDIR"
    msg "PKG_TAR    = $PKG_TARBALL"

    download_and_check_kernel
    prepare_dirs

    cd "$SRC_DIR"

    msg "Removendo diretório de build antigo (se existir): $KERNEL_DIR"
    rm -rf "$KERNEL_DIR"

    msg "Extraindo tarball: $TARBALL"
    tar -xf "$TARBALL"

    cd "$KERNEL_DIR"

    # Passos exatamente como no LFS 12.4 (adaptando só o destino) 3
    msg "Executando make mrproper (limpeza do source)..."
    make mrproper

    msg "Gerando headers com make headers ..."
    make headers

    msg "Removendo arquivos não .h de usr/include ..."
    find usr/include -type f ! -name '*.h' -delete

    # Instalar em DESTDIR (em vez de copiar direto para $LFS/usr)
    msg "Instalando headers em DESTDIR/usr/include ..."
    rm -rf "$DESTDIR"
    mkdir -p "$DESTDIR/usr"
    cp -rv usr/include "$DESTDIR/usr"

    # Copiar para o $LFS real (como o livro faz com $LFS/usr)
    msg "Copiando headers para $LFS/usr ..."
    cp -av "$DESTDIR/usr/." "$LFS/usr/"

    # Empacotar o DESTDIR em tar.zst
    msg "Empacotando DESTDIR em $PKG_TARBALL ..."
    cd "$DESTDIR"
    if ! command -v zstd >/dev/null 2>&1; then
        die "zstd não encontrado; não é possível gerar tar.zst."
    fi
    tar -cf - . | zstd -z -q -o "$PKG_TARBALL"

    # Limpeza do source
    cd "$SRC_DIR"
    msg "Removendo diretório de build: $KERNEL_DIR"
    rm -rf "$KERNEL_DIR"

    msg "==== Linux-${KERNEL_VERSION} API Headers concluído com sucesso ===="
}

main "$@"
