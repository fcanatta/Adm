#!/usr/bin/env bash
set -euo pipefail

#============================================================
#  GCC-15.2.0 - Pass 1 (Cross GCC para LFS)
#  - Segue LFS r12.4-46 (Cap. 5.3)
#  - Baixa GCC + GMP + MPFR + MPC
#  - Confere MD5
#  - Constrói cross GCC Pass 1
#  - Instala em DESTDIR e copia pra $LFS/tools
#  - Faz strip seguro dos binários do Pass 1
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

# Triplets host/target (mesma ideia do livro LFS)
LFS_HOST="$(uname -m)-pc-linux-gnu"
LFS_TGT="${LFS_TGT:-$(uname -m)-lfs-linux-gnu}"

export LFS
export LFS_HOST
export LFS_TGT

# PATH da toolchain temporária
export PATH="$LFS/tools/bin:/usr/bin:/bin"

# Não deixar variáveis do host poluírem o cross
unset CC CXX CPP LD AR AS NM STRIP RANLIB OBJDUMP OBJCOPY

#------------------------------------------------------------
# Configuração de versões e caminhos
#------------------------------------------------------------

PKG_NAME="gcc-pass1"

GCC_VERSION="${GCC_VERSION:-15.2.0}"
GMP_VERSION="${GMP_VERSION:-6.3.0}"
MPFR_VERSION="${MPFR_VERSION:-4.2.2}"
MPC_VERSION="${MPC_VERSION:-1.3.1}"
GLIBC_VERSION="${GLIBC_VERSION:-2.42}"

# URLs (pode sobrescrever via ambiente se quiser apontar pra mirror)
GCC_SRC_URL="${GCC_SRC_URL:-https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz}"
GMP_SRC_URL="${GMP_SRC_URL:-https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VERSION}.tar.xz}"
MPFR_SRC_URL="${MPFR_SRC_URL:-https://ftp.gnu.org/gnu/mpfr/mpfr-${MPFR_VERSION}.tar.xz}"
MPC_SRC_URL="${MPC_SRC_URL:-https://ftp.gnu.org/gnu/mpc/mpc-${MPC_VERSION}.tar.gz}"

# MD5 (ajuste se quiser usar outros mirrors/tarballs)
GCC_MD5="${GCC_MD5:-b861b092bf1af683c46a8aa2e689a6fd}"
GMP_MD5="${GMP_MD5:-956dc04e864001a9c22429f761f2c283}"
MPFR_MD5="${MPFR_MD5:-7c32c39b8b6e3ae85f25156228156061}"
MPC_MD5="${MPC_MD5:-5c9bc658c9fd0f940e8e3e0f09530c62}"

SRC_DIR="${SRC_DIR:-$LFS/sources}"

GCC_TARBALL="gcc-${GCC_VERSION}.tar.xz"
GMP_TARBALL="gmp-${GMP_VERSION}.tar.xz"
MPFR_TARBALL="mpfr-${MPFR_VERSION}.tar.xz"
MPC_TARBALL="mpc-${MPC_VERSION}.tar.gz"

GCC_DIR="gcc-${GCC_VERSION}"

DESTDIR="${DESTDIR:-$LFS/pkg/${PKG_NAME}}"

PKG_OUTPUT_DIR="${PKG_OUTPUT_DIR:-$LFS/packages}"
PKG_ARCH="${PKG_ARCH:-$(uname -m)}"
PKG_TARBALL="$PKG_OUTPUT_DIR/${PKG_NAME}-${GCC_VERSION}-${PKG_ARCH}.tar.zst"

if command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc)"
else
    JOBS=1
fi

#------------------------------------------------------------
# Funções auxiliares
#------------------------------------------------------------

msg() {
    # azul forte
    echo -e "\033[1;34m[$(date +'%F %T')] $*\033[0m"
}

die() {
    # vermelho forte
    echo -e "\033[1;31mERRO: $*\033[0m" >&2
    exit 1
}

download_and_check() {
    local tarball="$1" url="$2" md5="$3"

    mkdir -p "$SRC_DIR"
    cd "$SRC_DIR"

    if [[ -f "$tarball" ]]; then
        msg "Tarball já existe: $tarball"
    else
        msg "Baixando $url ..."
        if command -v wget >/dev/null 2>&1; then
            wget -c "$url" -O "$tarball"
        elif command -v curl >/dev/null 2>&1; then
            curl -L "$url" -o "$tarball"
        else
            die "Nem wget nem curl encontrados para baixar $tarball."
        fi
    fi

    if command -v md5sum >/dev/null 2>&1; then
        msg "Verificando MD5 de $tarball ..."
        echo "${md5}  ${tarball}" | md5sum -c - || die "MD5 inválido para $tarball"
    else
        msg "md5sum não encontrado; *não* foi possível verificar o MD5 de $tarball."
    fi
}

prepare_destdirs() {
    mkdir -p "$DESTDIR"
    mkdir -p "$PKG_OUTPUT_DIR"
    mkdir -p "$LFS/tools"
}

#------------------------------------------------------------
# Strip seguro para GCC Pass 1 (no DESTDIR)
#------------------------------------------------------------

strip_gcc_pass1() {
    msg "Executando strip seguro dos binários do GCC Pass 1 (DESTDIR=$DESTDIR)..."

    local HOST_STRIP
    if command -v strip >/dev/null 2>&1; then
        HOST_STRIP="strip"
    else
        die "strip não encontrado no sistema host."
    fi

    # Diretórios dentro do DESTDIR a serem varridos
    local STRIP_DIRS=(
        "$DESTDIR/tools/bin"
        "$DESTDIR/tools/libexec/gcc/$LFS_TGT"
        "$DESTDIR/tools/lib/gcc/$LFS_TGT"
    )

    local d
    for d in "${STRIP_DIRS[@]}"; do
        [[ -d "$d" ]] || continue

        msg "Strip em: $d"
        # Só arquivos ELF
        while IFS= read -r f; do
            if file "$f" | grep -q "ELF"; then
                $HOST_STRIP --strip-unneeded "$f" || true
            fi
        done < <(find "$d" -type f -print)
    done

    msg "Strip concluído (modo seguro para Pass 1)."
}

#------------------------------------------------------------
# Build
#------------------------------------------------------------

main() {
    msg "==== GCC ${GCC_VERSION} - Pass 1 ===="
    msg "LFS        = $LFS"
    msg "HOST       = $LFS_HOST"
    msg "TARGET     = $LFS_TGT"
    msg "PATH       = $PATH"
    msg "DESTDIR    = $DESTDIR"
    msg "PKG_TAR    = $PKG_TARBALL"

    # 1) Baixar & verificar GCC + libs
    download_and_check "$GCC_TARBALL" "$GCC_SRC_URL" "$GCC_MD5"
    download_and_check "$GMP_TARBALL"  "$GMP_SRC_URL"  "$GMP_MD5"
    download_and_check "$MPFR_TARBALL" "$MPFR_SRC_URL" "$MPFR_MD5"
    download_and_check "$MPC_TARBALL"  "$MPC_SRC_URL"  "$MPC_MD5"

    prepare_destdirs

    cd "$SRC_DIR"

    # 2) Extrair gcc
    msg "Removendo árvore anterior: $GCC_DIR"
    rm -rf "$GCC_DIR"

    msg "Extraindo $GCC_TARBALL ..."
    tar -xf "$GCC_TARBALL"

    cd "$GCC_DIR"

    # 3) Incorporar MPFR, GMP, MPC na árvore do GCC
    msg "Incorporando MPFR, GMP e MPC na árvore do GCC ..."
    tar -xf "../$MPFR_TARBALL"
    mv -v "mpfr-${MPFR_VERSION}" mpfr

    tar -xf "../$GMP_TARBALL"
    mv -v "gmp-${GMP_VERSION}" gmp

    tar -xf "../$MPC_TARBALL"
    mv -v "mpc-${MPC_VERSION}" mpc

    # 4) Ajuste do t-linux64 em x86_64 (lib vs lib64)
    case "$(uname -m)" in
        x86_64)
            msg "Ajustando t-linux64 para usar lib ao invés de lib64..."
            sed -e '/m64=/s/lib64/lib/' -i gcc/config/i386/t-linux64
        ;;
    esac

    # 5) Diretório de build separado
    msg "Criando diretório de build ..."
    mkdir -v build
    cd build

    # 6) Configure (LFS Pass 1)
    msg "Configurando GCC para o target $LFS_TGT ..."
    ../configure                          \
        --target="$LFS_TGT"               \
        --prefix=/tools                   \
        --with-glibc-version="$GLIBC_VERSION" \
        --with-sysroot="$LFS"             \
        --with-newlib                     \
        --without-headers                 \
        --enable-default-pie              \
        --enable-default-ssp              \
        --disable-nls                     \
        --disable-shared                  \
        --disable-multilib                \
        --disable-threads                 \
        --disable-libatomic               \
        --disable-libgomp                 \
        --disable-libquadmath             \
        --disable-libssp                  \
        --disable-libvtv                  \
        --disable-libstdcxx               \
        --enable-languages=c,c++

    # 7) Compilar
    msg "Compilando GCC (make -j$JOBS) ..."
    make -j"$JOBS"

    # 8) Instalar em DESTDIR
    msg "Instalando em DESTDIR=$DESTDIR ..."
    rm -rf "$DESTDIR"
    make DESTDIR="$DESTDIR" install

    # 9) Strip seguro no DESTDIR
    strip_gcc_pass1

    # 10) Copiar do DESTDIR para o $LFS/tools real
    msg "Copiando de DESTDIR/tools para $LFS/tools ..."
    cp -av "$DESTDIR/tools/." "$LFS/tools/"

    # 11) Criar o limits.h interno completo (como no livro)
    msg "Gerando limits.h interno para o cross GCC ..."
    cd ..
    cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
        "$(dirname "$($LFS_TGT-gcc -print-libgcc-file-name)")/include/limits.h"

    # 12) Empacotar o DESTDIR em tar.zst
    msg "Empacotando DESTDIR em $PKG_TARBALL ..."
    cd "$DESTDIR"
    if ! command -v zstd >/dev/null 2>&1; then
        die "zstd não encontrado; não é possível gerar tar.zst."
    fi
    tar -cf - . | zstd -z -q -o "$PKG_TARBALL"

    # 13) Limpeza do source
    cd "$SRC_DIR"
    msg "Removendo diretório de build: $GCC_DIR"
    rm -rf "$GCC_DIR"

    msg "==== GCC ${GCC_VERSION} - Pass 1 concluído com sucesso ===="
}

main "$@"
