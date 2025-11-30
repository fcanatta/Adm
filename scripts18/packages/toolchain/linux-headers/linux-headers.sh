#!/usr/bin/env bash
set -euo pipefail

#============================================================
#  Linux API Headers 6.17.8
#
#  - Baixa linux-6.17.8 do kernel.org
#  - Verifica SHA256 oficial
#  - Instala os headers em $LFS/usr/include
#    (make mrproper; make headers; copia usr/include)
#  - Gera linux-headers.version para o ADM
#
#  Uso:
#    - Normalmente com usuário 'lfs' (não root), com $LFS/mnt/lfs
#============================================================

# Não é recomendado rodar como root no estágio de LFS em /mnt/lfs
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "ERRO: NÃO execute este script como root quando estiver construindo em /mnt/lfs." >&2
    echo "      Use o usuário 'lfs' que é dono de \$LFS." >&2
    exit 1
fi

# Diretório do próprio script (pra gravar linux-headers.version)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# LFS padrão (se o ADM não tiver exportado)
: "${LFS:=/mnt/lfs}"

# Diretório dos sources
SRC_DIR="${LFS_SOURCES_DIR:-$LFS/sources}"

# Versão / tarball / URL
KVER="6.17.8"
PKG_FULL="linux-${KVER}"
TARBALL="${PKG_FULL}.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${TARBALL}"

# SHA256 oficial do linux-6.17.8.tar.xz (sha256sums.asc do kernel.org) 
SHA256_EXPECTED="2a6c40299ea9c49d03a4ecea23d128d6cabc1735e2dec4ae83401fda7241ab42"

echo "=== Linux API Headers $KVER ==="
echo "LFS........: $LFS"
echo "SRC_DIR....: $SRC_DIR"
echo "TARBALL....: $TARBALL"
echo "URL........: $URL"
echo "SHA256.....: $SHA256_EXPECTED"
echo

#------------------------------------------------------------
# Verificações básicas de ferramentas
#------------------------------------------------------------
for tool in wget sha256sum tar make find; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERRO: ferramenta obrigatória não encontrada no PATH: $tool" >&2
        exit 1
    fi
done

#============================================================
# Função: download + checagem SHA256
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
# 2. Baixar + checar o tarball do kernel
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
# 4. Limpeza e geração dos headers (estilo LFS)
#============================================================

# Garante árvore "limpa"
echo ">> Rodando make mrproper ..."
make mrproper

# Gera os headers exportados para user-space
echo ">> Rodando make headers ..."
make headers

# Remove tudo que não é .h dentro de usr/include
echo ">> Limpando arquivos não-.h em usr/include ..."
find usr/include -type f ! -name '*.h' -delete

#============================================================
# 5. Instalar headers em $LFS/usr/include
#============================================================
echo ">> Instalando headers em $LFS/usr/include ..."

mkdir -pv "$LFS/usr"
cp -rv usr/include "$LFS/usr"

echo ">> Headers instalados em: $LFS/usr/include"

#============================================================
# 6. Limpeza da árvore de fontes
#============================================================
cd "$SRC_DIR"
rm -rf "$PKG_FULL"

#============================================================
# 7. Registrar versão para o ADM (linux-headers.version)
#============================================================
echo "$KVER" > "$SCRIPT_DIR/linux-headers.version"

echo "=== Linux API Headers $KVER concluído com sucesso ==="
echo "Versão registrada em: $SCRIPT_DIR/linux-headers.version"
