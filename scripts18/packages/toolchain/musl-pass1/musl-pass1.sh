#!/usr/bin/env bash
set -euo pipefail

#============================================================
#  musl-1.2.5 - Pass 1
#
#  - Libc alvo do sistema LFS (musl) construída com cross-GCC
#  - Instala em $LFS (via DESTDIR)
#  - Aplica patches do advisory CVE-2025-26519:
#      https://www.openwall.com/lists/musl/2025/02/13/1/1
#      https://www.openwall.com/lists/musl/2025/02/13/1/2
#  - Gera musl-pass1.version para o ADM
#
#  Pré-requisitos:
#    - Cross toolchain já criado:
#        $LFS/tools/bin/$LFS_TGT-gcc etc.
#    - Usuário: NÃO root (use o usuário 'lfs')
#============================================================

# Não executar como root
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "ERRO: NÃO execute este script como root. Use o usuário 'lfs'." >&2
    exit 1
fi

# Diretório deste script (para gravar musl-pass1.version)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Se o ADM não definiu LFS, usar padrão
: "${LFS:=/mnt/lfs}"

# Diretório dos sources (padrão)
SRC_DIR="${LFS_SOURCES_DIR:-$LFS/sources}"

# Target padrão (igual usado pro GCC/Binutils)
: "${LFS_TGT:=$(uname -m)-lfs-linux-musl}"

# Versão do musl para este pass1
MUSL_VER="1.2.5"
PKG_NAME="musl"
PKG_FULL="${PKG_NAME}-${MUSL_VER}"
TARBALL="${PKG_FULL}.tar.gz"
URL="https://musl.libc.org/releases/${TARBALL}"

# SHA256 oficial do tarball (mesmo tarball usado por Debian) 
SHA256_EXPECTED="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

# Patches CVE-2025-26519 do advisory da musl (Openwall) 
PATCH1_URL="https://www.openwall.com/lists/musl/2025/02/13/1/1"
PATCH2_URL="https://www.openwall.com/lists/musl/2025/02/13/1/2"

echo "=== musl $MUSL_VER - Pass 1 ==="
echo "LFS..........: $LFS"
echo "LFS_TGT......: $LFS_TGT"
echo "SRC_DIR......: $SRC_DIR"
echo "TARBALL......: $TARBALL"
echo "URL..........: $URL"
echo "SHA256.......: $SHA256_EXPECTED"
echo

#------------------------------------------------------------
# Verificações básicas de ferramentas
#------------------------------------------------------------
for tool in wget sha256sum tar patch; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERRO: ferramenta obrigatória não encontrada no PATH: $tool" >&2
        exit 1
    fi
done

#============================================================
# Função genérica: download + checagem SHA256
#============================================================
download_and_check_sha256() {
    local url="$1"
    local file="$2"
    local sha_expected="$3"

    if [[ ! -f "$file" ]]; then
        echo ">> Baixando $file ..."
        wget -q --show-progress "$url" -O "$file"
    fi

    echo ">> Verificando SHA256 de $file ..."
    local sha_file
    sha_file="$(sha256sum "$file" | awk '{print $1}')"

    if [[ "$sha_file" != "$sha_expected" ]]; then
        echo "ERRO: SHA256 inválido para $file!" >&2
        echo "Esperado: $sha_expected" >&2
        echo "Obtido..: $sha_file" >&2
        echo "Apague o arquivo e rode o script novamente." >&2
        exit 1
    fi

    echo "SHA256 OK para $file."
    echo
}

#============================================================
# 1. Preparar diretório de sources
#============================================================
mkdir -pv "$SRC_DIR"
cd "$SRC_DIR"

#============================================================
# 2. Baixar + checar o tarball do musl
#============================================================
download_and_check_sha256 "$URL" "$TARBALL" "$SHA256_EXPECTED"

#============================================================
# 3. Extrair fonte
#============================================================
rm -rf "$PKG_FULL"
echo ">> Extraindo $TARBALL ..."
tar -xf "$TARBALL"

cd "$PKG_FULL"

#============================================================
# 4. Baixar e aplicar patches CVE-2025-26519
#============================================================
PATCH_DIR="$SRC_DIR/musl-${MUSL_VER}-patches"
mkdir -pv "$PATCH_DIR"

PATCH1_FILE="$PATCH_DIR/musl-CVE-2025-26519-1.patch"
PATCH2_FILE="$PATCH_DIR/musl-CVE-2025-26519-2.patch"

if [[ ! -f "$PATCH1_FILE" ]]; then
    echo ">> Baixando patch 1 (EUC-KR decoder fix)..."
    wget -q --show-progress "$PATCH1_URL" -O "$PATCH1_FILE"
fi

if [[ ! -f "$PATCH2_FILE" ]]; then
    echo ">> Baixando patch 2 (hardening UTF-8 output path)..."
    wget -q --show-progress "$PATCH2_URL" -O "$PATCH2_FILE"
fi

echo ">> Aplicando patch 1..."
patch -Np1 -i "$PATCH1_FILE"

echo ">> Aplicando patch 2..."
patch -Np1 -i "$PATCH2_FILE"

echo ">> Patches aplicados com sucesso."
echo

#============================================================
# 5. Configure (cross, instalando no sysroot $LFS via DESTDIR)
#============================================================
echo ">> Configurando musl (Pass 1)..."

# Garantir que o cross-compiler está na frente no PATH
export PATH="$LFS/tools/bin:$PATH"

# Configuração típica para usar musl como libc principal do alvo:
#   - prefix=/usr (dentro do DESTDIR)
#   - syslibdir=/lib (dentro do DESTDIR)
#   - CROSS_COMPILE=$LFS_TGT- (usa $LFS_TGT-gcc, etc.)
#
# Aqui usamos --disable-shared para um pass1 mais simples (estático).
./configure \
    CROSS_COMPILE="${LFS_TGT}-" \
    --prefix=/usr \
    --target="$LFS_TGT" \
    --syslibdir=/lib \
    --disable-shared

#============================================================
# 6. Compilar e instalar (em $LFS via DESTDIR)
#============================================================
echo ">> Compilando musl..."
make -j"$(nproc)"

echo ">> Instalando musl em \$LFS (DESTDIR=$LFS)..."
make DESTDIR="$LFS" install

#============================================================
# 7. Limpeza da árvore de fontes
#============================================================
cd "$SRC_DIR"
rm -rf "$PKG_FULL"

#============================================================
# 8. Registrar versão para o ADM (musl-pass1.version)
#============================================================
echo "$MUSL_VER" > "$SCRIPT_DIR/musl-pass1.version"

echo "=== musl $MUSL_VER - Pass 1 concluído com sucesso ==="
echo "Versão registrada em: $SCRIPT_DIR/musl-pass1.version"
