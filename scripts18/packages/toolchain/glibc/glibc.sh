#!/bin/bash
# Glibc-2.42 - construção para sistema final (LFS 12.4)
# Caminho sugerido: $LFS/packages/base/glibc/glibc.sh
# ATENÇÃO: este script deve ser executado DENTRO do chroot LFS
#          (ou no sistema LFS já bootado), com LFS=/.

set -euo pipefail

PKG_NAME="glibc"
PKG_VERSION="2.42"

# Mirror e arquivos alinhados com LFS 12.4
LFS_MIRROR="https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4"

GLIBC_TARBALL="glibc-${PKG_VERSION}.tar.xz"
GLIBC_MD5="23c6f5a27932b435cae94e087cb8b1f5"

FHS_PATCH="glibc-${PKG_VERSION}-fhs-1.patch"
FHS_PATCH_MD5="f75cca16a38da6caa7d52151f7136895"

TZDATA_VERSION="2025b"
TZDATA_TARBALL="tzdata${TZDATA_VERSION}.tar.gz"
TZDATA_MD5="ad65154c48c74a9b311fe84778c5434f"

# Pasta de fontes usada no chroot LFS
SOURCES_DIR="/sources"

# ──────────────────────────────────────────────────────────────
#  Checagens de segurança / ambiente
# ──────────────────────────────────────────────────────────────

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERRO: o glibc deve ser construído como root (dentro do chroot LFS)." >&2
    exit 1
fi

: "${LFS:=/}"

if [[ "$LFS" != "/" ]]; then
    cat >&2 <<EOF
ERRO: este script é para o sistema final e deve ser executado DENTRO do chroot
do LFS (ou no LFS já bootado), com:

    export LFS=/
    # e / apontando para o sistema LFS, NÃO para o host

EOF
    exit 1
fi

if [[ ! -d "$SOURCES_DIR" ]]; then
    echo "ERRO: diretório $SOURCES_DIR não existe. Verifique seu chroot LFS." >&2
    exit 1
fi

mkdir -p "$SOURCES_DIR"
cd "$SOURCES_DIR"

# ──────────────────────────────────────────────────────────────
#  Funções auxiliares
# ──────────────────────────────────────────────────────────────

download_and_check() {
    local file="$1"
    local url="$2"
    local md5_expected="$3"

    if [[ ! -f "$file" ]]; then
        echo ">> Baixando $file"
        curl -fL "$url" -o "$file"
    else
        echo ">> $file já existe, não baixando novamente"
    fi

    echo ">> Verificando MD5 de $file"
    echo "${md5_expected}  ${file}" | md5sum -c -
}

# ──────────────────────────────────────────────────────────────
#  Download + verificação de integridade
# ──────────────────────────────────────────────────────────────

download_and_check "$GLIBC_TARBALL" "${LFS_MIRROR}/${GLIBC_TARBALL}" "$GLIBC_MD5"
download_and_check "$FHS_PATCH"     "${LFS_MIRROR}/${FHS_PATCH}"     "$FHS_PATCH_MD5"
download_and_check "$TZDATA_TARBALL" "${LFS_MIRROR}/${TZDATA_TARBALL}" "$TZDATA_MD5"

# ──────────────────────────────────────────────────────────────
#  Extração e preparação
# ──────────────────────────────────────────────────────────────

echo ">> Limpando árvore antiga do glibc"
rm -rf "glibc-${PKG_VERSION}"
tar -xf "$GLIBC_TARBALL"
cd "glibc-${PKG_VERSION}"

echo ">> Aplicando patch FHS"
patch -Np1 -i "../${FHS_PATCH}"

echo ">> Aplicando workaround para Valgrind (abort.c fortify-validation)"
# (mesmo padrão usado no livro para evitar problema com Valgrind)
sed '/asm.*volatile.*asm/s/^/if (0) /' -i debug/fortify-validation/abort.c

# ──────────────────────────────────────────────────────────────
#  Construção (build directory separado)
# ──────────────────────────────────────────────────────────────

echo ">> Criando diretório de build"
rm -rf build
mkdir -p build
cd build

# Evitar flags de otimização estranhas herdadas do ambiente
unset CFLAGS CXXFLAGS

# rootsbindir garante programas administrativos em /usr/sbin
echo "rootsbindir=/usr/sbin" > configparms

echo ">> Configurando Glibc ${PKG_VERSION}"
../configure \
    --prefix=/usr \
    --disable-werror \
    --enable-kernel=4.19 \
    --enable-stack-protector=strong \
    --with-headers=/usr/include \
    libc_cv_slibdir=/usr/lib

echo ">> Compilando Glibc (isso pode demorar bastante)"
make

# ──────────────────────────────────────────────────────────────
#  Testes (opcional, mas recomendado)
#   - Use SKIP_TESTS=1 para pular.
# ──────────────────────────────────────────────────────────────

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
    echo ">> Rodando testes de Glibc (make check). Isso é MUITO demorado."
    echo "   Se algum teste falhar, o script continua mas avisa no log."

    # Evitar abortar o script em falhas de teste
    if ! make check; then
        echo "AVISO: Alguns testes de Glibc falharam. Verifique os logs em ${PWD}." >&2
    fi
else
    echo ">> SKIP_TESTS=1 definido, pulando make check"
fi

# ──────────────────────────────────────────────────────────────
#  Instalação
# ──────────────────────────────────────────────────────────────

# Arquivo de configuração do loader (caso ainda não exista)
if [[ ! -f /etc/ld.so.conf ]]; then
    echo ">> Criando /etc/ld.so.conf vazio"
    touch /etc/ld.so.conf
fi

echo ">> Instalando Glibc no sistema (make install)"
make install

# Opcional: aqui o LFS faz pequenos ajustes no ldd em algumas versões.
# Como isso é sensível à arquitetura e pode variar, NÃO fazemos um sed
# agressivo aqui. Se quiser, você pode replicar exatamente o sed do livro
# manualmente depois de conferir a sua arquitetura.

# ──────────────────────────────────────────────────────────────
#  Instalação de timezones (tzdata)
# ──────────────────────────────────────────────────────────────

echo ">> Instalação de timezones (tzdata ${TZDATA_VERSION})"

cd "$SOURCES_DIR/glibc-${PKG_VERSION}/build"

# Descompacta o tzdata na árvore de build do glibc
tar -xf "$SOURCES_DIR/${TZDATA_TARBALL}"

ZONEINFO=/usr/share/zoneinfo
mkdir -pv "${ZONEINFO}"/{posix,right}

# Conjunto padrão do LFS
for tz in etcetera southamerica northamerica europe africa antarctica asia australasia backward; do
    zic -L /dev/null   -d "${ZONEINFO}"       ${tz}
    zic -L /dev/null   -d "${ZONEINFO}/posix" ${tz}
    zic -L leapseconds -d "${ZONEINFO}/right" ${tz}
done

cp -v zone.tab zone1970.tab iso3166.tab "${ZONEINFO}"

# NÃO definimos /etc/localtime automaticamente porque isso depende da sua
# localização. Exemplos:
#   ln -sfv /usr/share/zoneinfo/UTC               /etc/localtime
#   ln -sfv /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
echo ">> Atenção: configure seu fuso horário com um link para /etc/localtime manualmente."

# ──────────────────────────────────────────────────────────────
#  Locales básicos
# ──────────────────────────────────────────────────────────────
# O livro gera muitos locales; aqui criamos alguns essenciais.
# Você pode adicionar mais conforme necessidade.

echo ">> Gerando alguns locales básicos (pode demorar um pouco)"

localedef -i C -f UTF-8 C.UTF-8 || true

# Inglês (US)
localedef -i en_US -f ISO-8859-1  en_US || true
localedef -i en_US -f UTF-8       en_US.UTF-8 || true

# Português (Brasil) – útil no seu caso
localedef -i pt_BR -f ISO-8859-1  pt_BR || true
localedef -i pt_BR -f UTF-8       pt_BR.UTF-8 || true

cat <<'EOF'

>> Glibc 2.42 instalado.
   - Timezones instalados em /usr/share/zoneinfo
   - NÃO esqueça de:
       * Ajustar /etc/localtime
       * Ajustar /etc/nsswitch.conf, /etc/ld.so.conf e etc conforme o livro LFS
EOF
