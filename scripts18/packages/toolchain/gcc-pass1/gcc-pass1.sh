#!/usr/bin/env bash
set -euo pipefail

#============================================================
#  GCC-15.2.0 - Pass 1 (LFS r12.4-46)
#  - Cross-GCC instalado em $LFS/tools
#  - Download automático + verificação MD5 dos tarballs:
#      gcc-15.2.0, mpfr-4.2.2, gmp-6.3.0, mpc-1.3.1
#  - Segue exatamente as instruções do livro para Pass 1
#  - Gera gcc-pass1.version (usado pelo ADM)
#============================================================

# Não deve rodar como root (toolchain de capítulo 5 é com usuário 'lfs')
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "ERRO: NÃO execute este script como root. Use o usuário 'lfs'." >&2
    exit 1
fi

# Diretório do próprio script (para gravar gcc-pass1.version aqui)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Se ADM não definiu LFS, usar padrão do livro
: "${LFS:=/mnt/lfs}"

# Diretório de sources (padrão LFS)
SRC_DIR="${LFS_SOURCES_DIR:-$LFS/sources}"

# Target padrão do livro
: "${LFS_TGT:=$(uname -m)-lfs-linux-gnu}"

# Versões / nomes
GCC_VER="15.2.0"
GCC_FULL="gcc-${GCC_VER}"
GCC_TARBALL="${GCC_FULL}.tar.xz"
GCC_URL="https://ftp.gnu.org/gnu/gcc/${GCC_FULL}/${GCC_TARBALL}"

MPFR_VER="4.2.2"
MPFR_FULL="mpfr-${MPFR_VER}"
MPFR_TARBALL="${MPFR_FULL}.tar.xz"
MPFR_URL="https://ftp.gnu.org/gnu/mpfr/${MPFR_TARBALL}"

GMP_VER="6.3.0"
GMP_FULL="gmp-${GMP_VER}"
GMP_TARBALL="${GMP_FULL}.tar.xz"
GMP_URL="https://ftp.gnu.org/gnu/gmp/${GMP_TARBALL}"

MPC_VER="1.3.1"
MPC_FULL="mpc-${MPC_VER}"
MPC_TARBALL="${MPC_FULL}.tar.gz"
MPC_URL="https://ftp.gnu.org/gnu/mpc/${MPC_TARBALL}"

# MD5 oficiais / confiáveis
GCC_MD5="b861b092bf1af683c46a8aa2e689a6fd"   # BLFS gcc-15.2.0.tar.xz 
MPFR_MD5="7c32c39b8b6e3ae85f25156228156061" # mpfr-4.2.2.orig.tar.xz 
GMP_MD5="956dc04e864001a9c22429f761f2c283"  # gmp-6.3.0.tar.xz 
MPC_MD5="5c9bc658c9fd0f940e8e3e0f09530c62"  # mpc-1.3.1.tar.gz 

echo "=== GCC $GCC_VER - Pass 1 ==="
echo "LFS.........: $LFS"
echo "LFS_TGT.....: $LFS_TGT"
echo "SRC_DIR.....: $SRC_DIR"
echo "GCC_TARBALL.: $GCC_TARBALL"
echo

#------------------------------------------------------------
# Verificações básicas de ferramentas
#------------------------------------------------------------
for tool in wget md5sum tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERRO: ferramenta obrigatória não encontrada no PATH: $tool" >&2
        exit 1
    fi
done

#============================================================
# Função genérica de download + conferência MD5
#============================================================
download_and_check() {
    local url="$1"
    local file="$2"
    local md5_expected="$3"

    if [[ ! -f "$file" ]]; then
        echo ">> Baixando $file ..."
        wget -q --show-progress "$url" -O "$file"
    fi

    echo ">> Verificando MD5 de $file ..."
    local md5_file
    md5_file="$(md5sum "$file" | awk '{print $1}')"

    if [[ "$md5_file" != "$md5_expected" ]]; then
        echo "ERRO: MD5 inválido para $file!" >&2
        echo "Esperado: $md5_expected" >&2
        echo "Obtido..: $md5_file" >&2
        echo "Apague o arquivo e rode o script novamente." >&2
        exit 1
    fi
    echo "MD5 OK para $file."
    echo
}

#============================================================
# 1. Preparar diretório de sources
#============================================================
mkdir -pv "$SRC_DIR"
cd "$SRC_DIR"

#============================================================
# 2. Download + MD5 de todos os tarballs necessários
#============================================================
download_and_check "$GCC_URL"  "$GCC_TARBALL"  "$GCC_MD5"
download_and_check "$MPFR_URL" "$MPFR_TARBALL" "$MPFR_MD5"
download_and_check "$GMP_URL"  "$GMP_TARBALL"  "$GMP_MD5"
download_and_check "$MPC_URL"  "$MPC_TARBALL"  "$MPC_MD5"

#============================================================
# 3. Extrair GCC e entrar no diretório
#============================================================
rm -rf "$GCC_FULL"
echo ">> Extraindo $GCC_TARBALL ..."
tar -xf "$GCC_TARBALL"

cd "$GCC_FULL"

#============================================================
# 4. Extrair MPFR, GMP, MPC dentro do source do GCC (como no LFS)
#============================================================
echo ">> Integrando MPFR $MPFR_VER, GMP $GMP_VER, MPC $MPC_VER no source do GCC..."

tar -xf "../$MPFR_TARBALL"
mv -v "$MPFR_FULL" mpfr

tar -xf "../$GMP_TARBALL"
mv -v "$GMP_FULL" gmp

tar -xf "../$MPC_TARBALL"
mv -v "$MPC_FULL" mpc

#============================================================
# 5. Ajuste t-linux64 para x86_64 (lib64 -> lib) – LFS 5.3
#============================================================
case "$(uname -m)" in
    x86_64)
        echo ">> Ajustando t-linux64 (lib64 -> lib) para x86_64..."
        sed -e '/m64=/s/lib64/lib/' -i gcc/config/i386/t-linux64
        ;;
esac

#============================================================
# 6. Build em diretório separado (build/)
#============================================================
echo ">> Criando diretório build/ ..."
mkdir -v build
cd       build

#============================================================
# 7. Configure (exatamente como no livro LFS r12.4-46)
#============================================================
echo ">> Configurando GCC (Pass 1)..."

../configure                  \
    --target="$LFS_TGT"       \
    --prefix="$LFS/tools"     \
    --with-glibc-version=2.42 \
    --with-sysroot="$LFS"     \
    --with-newlib             \
    --without-headers         \
    --enable-default-pie      \
    --enable-default-ssp      \
    --disable-nls             \
    --disable-shared          \
    --disable-multilib        \
    --disable-threads         \
    --disable-libatomic       \
    --disable-libgomp         \
    --disable-libquadmath     \
    --disable-libssp          \
    --disable-libvtv          \
    --disable-libstdcxx       \
    --enable-languages=c,c++

#============================================================
# 8. Compilar e instalar
#============================================================
echo ">> Compilando GCC (isso pode demorar)..."
make -j"$(nproc)"

echo ">> Instalando em $LFS/tools..."
make install

#============================================================
# 9. Criar limits.h interno completo (como no livro)
#============================================================
echo ">> Gerando limits.h interno completo para o cross-GCC..."

cd ..
# Garantir que o cross-compiler está no PATH
PATH="$LFS/tools/bin:$PATH"

libgcc_file="$($LFS_TGT-gcc -print-libgcc-file-name)"
libgcc_dir="$(dirname "$libgcc_file")"

mkdir -p "$libgcc_dir/include"

cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
    "$libgcc_dir/include/limits.h"

echo ">> limits.h criado em: $libgcc_dir/include/limits.h"

#============================================================
# 10. Limpeza do source (opcional mas padrão LFS)
#============================================================
cd "$SRC_DIR"
rm -rf "$GCC_FULL"

#============================================================
# 11. Registrar versão para o ADM (gcc-pass1.version)
#============================================================
echo "$GCC_VER" > "$SCRIPT_DIR/gcc-pass1.version"

echo "=== GCC $GCC_VER - Pass 1 concluído com sucesso ==="
echo "Versão registrada em: $SCRIPT_DIR/gcc-pass1.version"
