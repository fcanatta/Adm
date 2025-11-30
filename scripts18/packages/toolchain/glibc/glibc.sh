#!/usr/bin/env bash
set -euo pipefail

#============================================================
#  Glibc-2.42 (LFS 12.4 - Cap. 5.5)
#  - Baixa glibc + patch FHS
#  - Verifica MD5
#  - Constrói em build dir separado
#  - Instala em DESTDIR (fake root)
#  - Copia para $LFS
#  - Executa sanity checks do livro
#  - Empacota em tar.zst
#============================================================

#------------------------------------------------------------
# Ambiente e triplets
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

# Usar toolchain temporária
export PATH="$LFS/tools/bin:/usr/bin:/bin"

#------------------------------------------------------------
# Configuração de versões e caminhos
#------------------------------------------------------------

PKG_NAME="glibc"

GLIBC_VERSION="${GLIBC_VERSION:-2.42}"

SRC_DIR="${SRC_DIR:-$LFS/sources}"

GLIBC_TARBALL="glibc-${GLIBC_VERSION}.tar.xz"
GLIBC_DIR="glibc-${GLIBC_VERSION}"

# URLs oficiais (do livro LFS 12.4) 
GLIBC_SRC_URL="${GLIBC_SRC_URL:-https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VERSION}.tar.xz}"
GLIBC_PATCH_URL="${GLIBC_PATCH_URL:-https://www.linuxfromscratch.org/patches/lfs/12.4/glibc-2.42-fhs-1.patch}"

GLIBC_MD5="${GLIBC_MD5:-23c6f5a27932b435cae94e087cb8b1f5}"
GLIBC_PATCH_MD5="${GLIBC_PATCH_MD5:-9a5997c3452909b1769918c759eff8a2}"

GLIBC_PATCH="glibc-2.42-fhs-1.patch"

# DESTDIR para empacotamento
DESTDIR="${DESTDIR:-$LFS/pkg/${PKG_NAME}}"

PKG_OUTPUT_DIR="${PKG_OUTPUT_DIR:-$LFS/packages}"
PKG_ARCH="${PKG_ARCH:-$(uname -m)}"
PKG_TARBALL="$PKG_OUTPUT_DIR/${PKG_NAME}-${GLIBC_VERSION}-${PKG_ARCH}.tar.zst"

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

download_file() {
    local url="$1" out="$2"

    mkdir -p "$SRC_DIR"
    cd "$SRC_DIR"

    if [[ -f "$out" ]]; then
        msg "Arquivo já existe: $SRC_DIR/$out"
    else
        msg "Baixando $url ..."
        if command -v wget >/dev/null 2>&1; then
            wget -c "$url" -O "$out"
        elif command -v curl >/dev/null 2>&1; then
            curl -L "$url" -o "$out"
        else
            die "Nem wget nem curl encontrados para baixar $out."
        fi
    fi
}

check_md5() {
    local file="$1" expected="$2"

    if ! command -v md5sum >/dev/null 2>&1; then
        msg "md5sum não encontrado; ignorando verificação de MD5 de $file."
        return 0
    fi

    msg "Verificando MD5 de $file ..."
    echo "${expected}  ${file}" | md5sum -c - || die "MD5 inválido para $file"
    msg "MD5 OK para $file."
}

prepare_dirs() {
    mkdir -p "$DESTDIR"
    mkdir -p "$PKG_OUTPUT_DIR"
    mkdir -p "$LFS/usr"
}

#------------------------------------------------------------
# Sanity checks da toolchain (do livro LFS) 3
#------------------------------------------------------------

sanity_checks() {
    msg "Executando sanity checks da Glibc (dummy.c / dummy.log)..."

    cd "$SRC_DIR/$GLIBC_DIR/build"

    echo 'int main(){}' | $LFS_TGT-gcc -x c - -v -Wl,--verbose &> dummy.log
    readelf -l a.out | grep ': /lib'

    grep -E -o "$LFS/lib.*/S?crt[1in].*succeeded" dummy.log
    grep -B3 "^ $LFS/usr/include" dummy.log
    grep 'SEARCH.*/usr/lib' dummy.log | sed 's|; |\n|g'
    grep "/lib.*/libc.so.6 " dummy.log
    grep found dummy.log

    rm -v a.out dummy.log
    msg "Sanity checks concluídos (veja saída acima para conferir)."
}

#------------------------------------------------------------
# Build / Install / Package
#------------------------------------------------------------

main() {
    msg "==== Glibc ${GLIBC_VERSION} (LFS cross, cap. 5.5) ===="
    msg "LFS        = $LFS"
    msg "HOST       = $LFS_HOST"
    msg "TARGET     = $LFS_TGT"
    msg "PATH       = $PATH"
    msg "DESTDIR    = $DESTDIR"
    msg "PKG_TAR    = $PKG_TARBALL"

    # 1) Baixar tarball e patch
    download_file "$GLIBC_SRC_URL"   "$GLIBC_TARBALL"
    download_file "$GLIBC_PATCH_URL" "$GLIBC_PATCH"

    # 2) Verificar MD5
    check_md5 "$GLIBC_TARBALL" "$GLIBC_MD5"
    check_md5 "$GLIBC_PATCH"   "$GLIBC_PATCH_MD5"

    prepare_dirs

    # 3) Symlinks LSB (como no livro) 4
    msg "Criando symlinks LSB em $LFS/lib* ..."
    case "$(uname -m)" in
        i?86)
            ln -sfv ld-linux.so.2 "$LFS/lib/ld-lsb.so.3"
        ;;
        x86_64)
            mkdir -p "$LFS/lib64"
            ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64"
            ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64/ld-lsb-x86-64.so.3"
        ;;
    esac

    cd "$SRC_DIR"

    # 4) Extrair source limpo
    msg "Removendo diretório anterior: $GLIBC_DIR"
    rm -rf "$GLIBC_DIR"

    msg "Extraindo $GLIBC_TARBALL ..."
    tar -xf "$GLIBC_TARBALL"

    cd "$GLIBC_DIR"

    # 5) Aplicar patch FHS 5
    msg "Aplicando patch FHS glibc-2.42-fhs-1.patch ..."
    patch -Np1 -i "../$GLIBC_PATCH"

    # 6) Build dir
    msg "Criando diretório de build ..."
    mkdir -v build
    cd build

    # 7) rootsbindir = /usr/sbin
    msg "Configurando rootsbindir=/usr/sbin ..."
    echo "rootsbindir=/usr/sbin" > configparms

    # 8) Configure (igual LFS 12.4 cap. 5.5) 6
    msg "Rodando configure da Glibc (cross, host=$LFS_TGT) ..."
    ../configure                             \
        --prefix=/usr                        \
        --host="$LFS_TGT"                    \
        --build="$(../scripts/config.guess)" \
        --disable-nscd                       \
        libc_cv_slibdir=/usr/lib             \
        --enable-kernel=5.4

    # 9) Compilar (sem -j por segurança, como recomendado)
    msg "Compilando Glibc (make, pode demorar)..."
    make

    # 10) Instalar em DESTDIR (fake root)
    msg "Instalando em DESTDIR=$DESTDIR ..."
    rm -rf "$DESTDIR"
    make DESTDIR="$DESTDIR" install

    # 11) Copiar DESTDIR -> $LFS (fica igual ao livro, que usa DESTDIR=$LFS)
    msg "Copiando conteúdo de DESTDIR para $LFS ..."
    cp -av "$DESTDIR/." "$LFS/"

    # 12) Corrigir ldd (hardcoded loader path) 7
    msg "Ajustando script ldd em $LFS/usr/bin/ldd ..."
    sed '/RTLDLIST=/s@/usr@@g' -i "$LFS/usr/bin/ldd"

    # 13) Sanity checks da toolchain
    sanity_checks

    # 14) Empacotar DESTDIR em tar.zst
    msg "Empacotando DESTDIR em $PKG_TARBALL ..."
    cd "$DESTDIR"
    if ! command -v zstd >/dev/null 2>&1; then
        die "zstd não encontrado; não é possível gerar tar.zst."
    fi
    tar -cf - . | zstd -z -q -o "$PKG_TARBALL"

    # 15) Limpeza do source
    cd "$SRC_DIR"
    msg "Removendo diretório de build: $GLIBC_DIR"
    rm -rf "$GLIBC_DIR"

    msg "==== Glibc ${GLIBC_VERSION} concluída com sucesso ===="
}

main "$@"
