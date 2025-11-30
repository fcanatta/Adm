#!/usr/bin/env bash
set -euo pipefail

#============================================================
#  Binutils-2.45.1 - Pass 1 (LFS r12.4)
#  - Cross-Binutils instalado em $LFS/tools
#  - Download automático + verificação MD5
#  - Strip em $LFS/tools
#  - Gera arquivo de versão para o ADM:
#       binutils-pass1.version
#============================================================

# Não deve rodar como root (etapas de toolchain são com usuário 'lfs')
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "ERRO: NÃO execute este script como root. Use o usuário 'lfs'." >&2
    exit 1
fi

# Diretório do próprio script (para gerar .version aqui)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Se ADM não fornecer LFS, usa padrão
: "${LFS:=/mnt/lfs}"

# Diretório padrão de sources
SRC_DIR="${LFS_SOURCES_DIR:-$LFS/sources}"

# Target padrão do livro (definido normalmente no .bashrc do usuário lfs)
: "${LFS_TGT:=$(uname -m)-lfs-linux-gnu}"

PKG_NAME="binutils"
PKG_VER="2.45.1"
PKG_FULL="${PKG_NAME}-${PKG_VER}"
TARBALL="${PKG_FULL}.tar.xz"

# URL oficial (LFS development / r12.4)
URL="https://sourceware.org/pub/binutils/releases/${TARBALL}"

# MD5 oficial do LFS para binutils-2.45.1.tar.xz
MD5_EXPECTED="ff59f8dc1431edfa54a257851bea74e7"

echo "=== ${PKG_NAME^} $PKG_VER - Pass 1 ==="
echo "LFS.......: $LFS"
echo "LFS_TGT...: $LFS_TGT"
echo "SRC_DIR...: $SRC_DIR"
echo "TARBALL...: $TARBALL"
echo "URL.......: $URL"
echo "MD5.......: $MD5_EXPECTED"
echo

#------------------------------------------------------------
# 0. Verificações de ferramentas
#------------------------------------------------------------
for tool in wget md5sum tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERRO: ferramenta obrigatória não encontrada no PATH: $tool" >&2
        exit 1
    fi
done

# strip é opcional, mas avisamos se não existir
if ! command -v strip >/dev/null 2>&1; then
    echo "AVISO: 'strip' não encontrado no PATH. Etapa de strip será ignorada." >&2
    HAVE_STRIP=0
else
    HAVE_STRIP=1
fi

#============================================================
# 1. Preparar diretório de sources
#============================================================
mkdir -pv "$SRC_DIR"
cd "$SRC_DIR"

#============================================================
# 2. Download automático (somente se não existir)
#============================================================
if [[ ! -f "$TARBALL" ]]; then
    echo ">> Baixando $TARBALL ..."
    wget -q --show-progress "$URL" -O "$TARBALL"
fi

#============================================================
# 3. Verificar MD5SUM
#============================================================
echo ">> Verificando integridade (md5sum)..."
MD5_FILE="$(md5sum "$TARBALL" | awk '{print $1}')"

if [[ "$MD5_FILE" != "$MD5_EXPECTED" ]]; then
    echo "ERRO: MD5 inválido para $TARBALL!" >&2
    echo "Esperado: $MD5_EXPECTED" >&2
    echo "Obtido..: $MD5_FILE" >&2
    echo "Apague o tarball e rode o script novamente." >&2
    exit 1
fi
echo "MD5 OK!"
echo

#============================================================
# 4. Extrair fonte e entrar no diretório
#============================================================
rm -rf "$PKG_FULL"
echo ">> Extraindo $TARBALL ..."
tar -xf "$TARBALL"

cd "$PKG_FULL"

echo ">> Criando diretório build/ ..."
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
if [[ "$HAVE_STRIP" -eq 1 ]]; then
    echo ">> STRIP nos binários do toolchain em $LFS/tools..."

    find "$LFS/tools" -type f -executable -print0 | \
        while IFS= read -r -d '' f; do
            case "$f" in
                *.a|*.la)
                    # não faz muito sentido strip em libs estáticas ou .la
                    ;;
                *)
                    strip --strip-unneeded "$f" 2>/dev/null || true
                    ;;
            esac
        done

    echo ">> STRIP concluído."
else
    echo ">> STRIP pulado (strip não disponível)."
fi

#============================================================
# 8. Limpeza segundo o padrão LFS
#============================================================
cd "$SRC_DIR"
rm -rf "$PKG_FULL"

#============================================================
# 9. Registrar versão para o ADM (binutils-pass1.version)
#============================================================
# O ADM vai ler esse arquivo para preencher o campo VERSION
# na meta do pacote "binutils-pass1".
echo "$PKG_VER" > "$SCRIPT_DIR/binutils-pass1.version"

echo "=== Binutils $PKG_VER - Pass 1 concluído com sucesso ==="
echo "Versão registrada em: $SCRIPT_DIR/binutils-pass1.version"
