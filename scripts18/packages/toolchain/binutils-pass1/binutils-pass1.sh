#!/usr/bin/env bash
set -euo pipefail

#============================================================
#  Binutils - Pass 1 (Cross Binutils para LFS)
#  Baseado em LFS 12.x - Binutils 2.41 - Pass 1
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

# Versão padrão do binutils (pode sobrescrever com BINUTILS_VERSION no ambiente)
BINUTILS_VERSION="${BINUTILS_VERSION:-2.41}"

SRC_DIR="$LFS/sources"
TARBALL="binutils-${BINUTILS_VERSION}.tar.xz"
PKG_DIR="binutils-${BINUTILS_VERSION}"

# Diretório de logs (opcional, cai em $LFS/logs por padrão)
LFS_LOG_DIR="${LFS_LOG_DIR:-$LFS/logs}"
LOG_DIR="$LFS_LOG_DIR"
LOG_FILE="$LOG_DIR/binutils-pass1.log"

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

#------------------------------------------------------------
# Preparar ambiente de log
#------------------------------------------------------------

mkdir -p "$LOG_DIR"

# Redireciona stdout/stderr para o log, mantendo eco no terminal
exec > >(tee -i "$LOG_FILE") 2>&1

log "Iniciando build do Binutils Pass 1 (versão $BINUTILS_VERSION)"
log "LFS=$LFS"
log "LFS_TGT=$LFS_TGT"
log "JOBS=$JOBS"
log "Log em: $LOG_FILE"

#------------------------------------------------------------
# Verificações de pré-requisitos
#------------------------------------------------------------

[[ -d "$SRC_DIR" ]] || die "Diretório de sources não existe: $SRC_DIR"
[[ -f "$SRC_DIR/$TARBALL" ]] || die "Tarball não encontrado: $SRC_DIR/$TARBALL"
[[ -d "$LFS/tools" ]] || die "Diretório $LFS/tools não existe. Execute o 'init' do LFS primeiro."

#------------------------------------------------------------
# Extração e preparação do diretório de build
#------------------------------------------------------------

cd "$SRC_DIR"

log "Removendo diretório anterior (se existir): $PKG_DIR"
rm -rf "$PKG_DIR"

log "Extraindo tarball: $TARBALL"
tar -xf "$TARBALL"

cd "$PKG_DIR"

log "Criando diretório de build fora da árvore de fontes"
mkdir -v build
cd build

#------------------------------------------------------------
# Configuração
#------------------------------------------------------------
log "Rodando configure (cross binutils Pass 1)..."

# Opções alinhadas com o livro LFS 12.0 para Binutils-2.41 - Pass 1 
../configure \
    --prefix="$LFS/tools" \
    --with-sysroot="$LFS" \
    --target="$LFS_TGT"   \
    --disable-nls         \
    --enable-gprofng=no   \
    --disable-werror

#------------------------------------------------------------
# Compilação
#------------------------------------------------------------
log "Compilando Binutils (make -j$JOBS)..."
make -j"$JOBS"

#------------------------------------------------------------
# Instalação
#------------------------------------------------------------
log "Instalando em $LFS/tools ..."
make install

#------------------------------------------------------------
# Pós-instalação
#------------------------------------------------------------
cd "$SRC_DIR"
log "Limpando diretório de build: removendo $PKG_DIR"
rm -rf "$PKG_DIR"

log "Binutils Pass 1 concluído com sucesso."
