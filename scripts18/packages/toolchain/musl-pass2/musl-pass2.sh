#!/usr/bin/env bash
set -euo pipefail

#============================================================
#  musl-1.2.5 - Pass 2
#
#  - Build "final" da libc musl para o sistema
#  - Usa cross toolchain já existente (CROSS_COMPILE=$LFS_TGT-)
#  - Instala em $LFS (via DESTDIR)
#  - Aplica patches CVE-2025-26519 (mesmos do Pass 1):
#      https://www.openwall.com/lists/musl/2025/02/13/1/1
#      https://www.openwall.com/lists/musl/2025/02/13/1/2
#  - Gera musl-pass2.version para o ADM
#
#  Pode ser usado em:
#    - Fase final antes do chroot (LFS=/mnt/lfs)
#    - Dentro do sistema já bootado (LFS=/)
#
#============================================================

# Em geral NÃO se executa como root enquanto ainda está em /mnt/lfs,
# mas se LFS="/" você provavelmente estará como root dentro do sistema.
if [[ "${LFS:-}" != "/" && "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "ERRO: não execute musl-pass2 como root quando LFS != '/'. Use o usuário 'lfs'." >&2
    exit 1
fi

# Diretório deste script (para gravar musl-pass2.version)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Se o ADM não definiu LFS, usar padrão
: "${LFS:=/mnt/lfs}"

# Diretório dos sources
SRC_DIR="${LFS_SOURCES_DIR:-$LFS/sources}"

# Target padrão (para musl); se você usa outro triplet, ajuste aqui
: "${LFS_TGT:=$(uname -m)-linux-musl}"

# Versão do musl
MUSL_VER="1.2.5"
PKG_NAME="musl"
PKG_FULL="${PKG_NAME}-${MUSL_VER}"
TARBALL="${PKG_FULL}.tar.gz"
URL="https://musl.libc.org/releases/${TARBALL}"

# SHA256 oficial do tarball (igual ao tarball upstream/orig) 
SHA256_EXPECTED="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

# Patches CVE-2025-26519 (os mesmos do Pass 1) 
PATCH1_URL="https://www.openwall.com/lists/musl/2025/02/13/1/1"
PATCH2_URL="https://www.openwall.com/lists/musl/2025/02/13/1/2"

echo "=== musl $MUSL_VER - Pass 2 ==="
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
for tool in wget sha256sum tar patch make; do
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
    echo ">> Baixando patch 2 (UTF-8 output path hardening)..."
    wget -q --show-progress "$PATCH2_URL" -O "$PATCH2_FILE"
fi

echo ">> Aplicando patch 1..."
patch -Np1 -i "$PATCH1_FILE"

echo ">> Aplicando patch 2..."
patch -Np1 -i "$PATCH2_FILE"

echo ">> Patches aplicados com sucesso."
echo

#============================================================
# 5. Configure (build "final" da musl)
#============================================================
echo ">> Configurando musl (Pass 2)..."

# Para garantir que o cross-compiler seja usado quando LFS != "/"
if [[ "$LFS" != "/" ]]; then
    export PATH="$LFS/tools/bin:$PATH"
fi

# Se você quiser build estritamente nativo quando LFS="/",
# pode comentar CROSS_COMPILE abaixo nessa condição.
CONFIG_ARGS=(
    "--prefix=/usr"
    "--syslibdir=/lib"
)

if [[ "$LFS" != "/" ]]; then
    CONFIG_ARGS+=(
        "CROSS_COMPILE=${LFS_TGT}-"
        "--target=$LFS_TGT"
    )
fi

# Aqui NÃO passamos --disable-shared, ou seja:
#   - libc.so + ld-musl-<arch>.so.1
#   - libc.a
./configure "${CONFIG_ARGS[@]}"

#============================================================
# 6. Compilar e instalar em $LFS
#============================================================
echo ">> Compilando musl..."
make -j"$(nproc)"

echo ">> Instalando musl (DESTDIR=$LFS)..."
make DESTDIR="$LFS" install

#============================================================
# 7. Limpeza da árvore de fontes
#============================================================
cd "$SRC_DIR"
rm -rf "$PKG_FULL"

#============================================================
# 8. Registrar versão para o ADM (musl-pass2.version)
#============================================================
echo "$MUSL_VER" > "$SCRIPT_DIR/musl-pass2.version"

echo "=== musl $MUSL_VER - Pass 2 concluído com sucesso ==="
echo "Versão registrada em: $SCRIPT_DIR/musl-pass2.version"
