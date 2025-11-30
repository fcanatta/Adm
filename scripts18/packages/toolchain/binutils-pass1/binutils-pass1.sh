#!/usr/bin/env bash
set -euo pipefail

#============================================================
#  Binutils-2.45.1 - Pass 1 (LFS r12.4-46)
#  Agora com:
#     - DOWNLOAD automático
#     - Verificação MD5
#     - STRIP automático após instalação
#============================================================

# Não deve rodar como root (etapa cross-toolchain)
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "ERRO: NÃO execute este script como root. Use o usuário 'lfs'." >&2
    exit 1
fi

# Se ADM não forneceu LFS, usar padrão
: "${LFS:=/mnt/lfs}"

# Diretório padrão de sources
SRC_DIR="${LFS_SOURCES_DIR:-$LFS/sources}"

# Target padrão do livro
LFS_TGT="${LFS_TGT:-$(uname -m)-lfs-linux-gnu}"
# Host
LFS_HOST="$(uname -m)-pc-linux-gnu"        

PKG_NAME="binutils"
PKG_VER="2.45.1"
PKG_FULL="${PKG_NAME}-${PKG_VER}"
TARBALL="${PKG_FULL}.tar.xz"
URL="https://ftp.gnu.org/gnu/binutils/${TARBALL}"

# MD5 oficial do Binutils 2.45.1
MD5_EXPECTED="c6fbafa502fa935eb94d8b9a5d7235a4"

echo "=== Binutils $PKG_VER - Pass 1 ==="
echo "LFS.......: $LFS"
echo "SRC_DIR...: $SRC_DIR"
echo "TARBALL...: $TARBALL"
echo "URL.......: $URL"
echo "MD5.......: $MD5_EXPECTED"
echo


#============================================================
# 1. Preparar diretório de sources
#============================================================
mkdir -pv "$SRC_DIR"
cd "$SRC_DIR"


#============================================================
# 2. DOWNLOAD automático (somente se não existir)
#============================================================
if [[ ! -f "$TARBALL" ]]; then
    echo ">> Baixando $TARBALL ..."
    wget -q --show-progress "$URL"
fi


#============================================================
# 3. Verificar MD5SUM
#============================================================
echo ">> Verificando integridade (md5sum)..."
MD5_FILE="$(md5sum "$TARBALL" | awk '{print $1}')"

if [[ "$MD5_FILE" != "$MD5_EXPECTED" ]]; then
    echo "ERRO: MD5 inválido!"
    echo "Esperado: $MD5_EXPECTED"
    echo "Obtido..: $MD5_FILE"
    exit 1
fi
echo "MD5 OK!"


#============================================================
# 4. Extrair fonte e entrar no diretório
#============================================================
rm -rf "$PKG_FULL"
echo ">> Extraindo $TARBALL ..."
tar -xf "$TARBALL"

cd "$PKG_FULL"
mkdir -v build
cd build


#============================================================
# 5. Configurar (exatamente como no LFS)
#============================================================
echo ">> Configurando Binutils (Pass 1)..."

../configure --prefix="$LFS/tools" \
             --with-sysroot="$LFS" \
             --target="$LFS_TGT"   \
             --disable-nls         \
             --enable-gprofng=no   \
             --disable-werror      \
             --enable-new-dtags    \
             --enable-default-hash-style=gnu


#============================================================
# 6. Compilar e instalar
#============================================================
echo ">> Compilando..."
make -j"$(nproc)"

echo ">> Instalando em $LFS/tools..."
make install


#============================================================
# 7. STRIP automático dentro de $LFS/tools
#============================================================
echo ">> STRIP nos binários do toolchain..."

find "$LFS/tools" -type f -executable -print0 | \
    while IFS= read -r -d '' f; do
        case "$f" in
            *.a|*.la)
                # não stripar libs estáticas (não é útil)
                ;;
            *)
                strip --strip-unneeded "$f" 2>/dev/null || true
                ;;
        esac
    done

echo ">> STRIP concluído."


#============================================================
# 8. Limpeza segundo o padrão LFS
#============================================================
cd "$SRC_DIR"
rm -rf "$PKG_FULL"

echo "=== Binutils $PKG_VER - Pass 1 concluído com sucesso ===" 
