#!/usr/bin/env bash
# Pacote: GCC 15.2.0 - Pass 1 (cross-compiler)
# Categoria: toolchain
# Este script constrói o GCC cross, conforme LFS 12.4 (Pass 1),
# usando /tools como prefix e $ROOTFS como sysroot.

PKG_NAME="gcc-pass1"
PKG_CATEGORY="toolchain"
PKG_VERSION="15.2.0"
PKG_DESC="GCC 15.2.0 - Pass 1 (cross-compiler para o toolchain LFS)"
PKG_HOMEPAGE="https://gcc.gnu.org/"

# Usando MD5 porque o ADM já suporta seleção de algoritmo via PKG_CHECKSUM_TYPE
PKG_CHECKSUM_TYPE="md5"

# IMPORTANTE: a ordem importa. O primeiro precisa ser o tarball do GCC
# porque o ADM escolhe o primeiro diretório extraído como SRC_DIR.
PKG_SOURCE=(
  "https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz"
  "https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz"
  "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
  "https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"
)

# MD5 oficiais (GCC e LFS 12.x)
PKG_CHECKSUMS=(
  "b861b092bf1af683c46a8aa2e689a6fd" # gcc-15.2.0.tar.xz
  "7c32c39b8b6e3ae85f25156228156061" # mpfr-4.2.2.tar.xz
  "956dc04e864001a9c22429f761f2c283" # gmp-6.3.0.tar.xz
  "5c9bc658c9fd0f940e8e3e0f09530c62" # mpc-1.3.1.tar.gz
)

# Dependência lógica: binutils pass 1 já precisa existir
PKG_DEPENDS=(
  "toolchain/binutils-pass1"
)

pkg_build() {
    # SRC_DIR, BUILD_DIR, ROOTFS, DESTDIR já vêm do ADM:
    #   SRC_DIR  -> diretório de fontes (gcc-15.2.0)
    #   BUILD_DIR -> área de build do pacote
    #   ROOTFS   -> /mnt/lfs (ou equivalente)
    #   DESTDIR  -> staging do pacote

    # Pastas auxiliares (onde o ADM extraiu todos os tarballs)
    local src_root
    src_root="$(dirname "$SRC_DIR")"

    echo "==> Preparando subpacotes GMP/MPFR/MPC dentro da árvore do GCC..."

    # Move MPFR para dentro de gcc/
    if [[ -d "$src_root/mpfr-4.2.2" && ! -d "$SRC_DIR/mpfr" ]]; then
        mv -v "$src_root/mpfr-4.2.2" "$SRC_DIR/mpfr"
    fi

    # Move GMP para dentro de gcc/
    if [[ -d "$src_root/gmp-6.3.0" && ! -d "$SRC_DIR/gmp" ]]; then
        mv -v "$src_root/gmp-6.3.0" "$SRC_DIR/gmp"
    fi

    # Move MPC para dentro de gcc/
    if [[ -d "$src_root/mpc-1.3.1" && ! -d "$SRC_DIR/mpc" ]]; then
        mv -v "$src_root/mpc-1.3.1" "$SRC_DIR/mpc"
    fi

    cd "$SRC_DIR"

    # Em hosts x86_64, usar lib em vez de lib64 para libs 64-bit
    case "$(uname -m)" in
        x86_64)
            sed -e '/m64=/s/lib64/lib/' -i gcc/config/i386/t-linux64
            ;;
    esac

    # Diretório de build separado, como recomendado pelo GCC
    mkdir -pv build
    cd build

    # LFS_TGT deve vir do perfil do ADM (ex: x86_64-lfs-linux-gnu)
    if [[ -z "${LFS_TGT:-}" ]]; then
        echo "ERRO: LFS_TGT não definido no perfil do ADM. Verifique seu profile."
        exit 1
    fi

    # ROOTFS é o sysroot (ex: /mnt/lfs)
    if [[ -z "${ROOTFS:-}" ]]; then
        echo "ERRO: ROOTFS não definido (vem do ADM)."
        exit 1
    fi

    echo "==> Configurando GCC 15.2.0 - Pass 1..."
    ../configure \
        --target="$LFS_TGT"         \
        --prefix=/tools             \
        --with-glibc-version=2.42   \
        --with-sysroot="$ROOTFS"    \
        --with-newlib               \
        --without-headers           \
        --enable-default-pie        \
        --enable-default-ssp        \
        --disable-nls               \
        --disable-shared            \
        --disable-multilib          \
        --disable-threads           \
        --disable-libatomic         \
        --disable-libgomp           \
        --disable-libquadmath       \
        --disable-libssp            \
        --disable-libvtv            \
        --disable-libstdcxx         \
        --enable-languages=c,c++

    echo "==> Compilando GCC (isso leva um tempo)..."
    make -j"$(nproc)"
}

pkg_install() {
    # Ainda estamos em $SRC_DIR/build por causa do fluxo do ADM
    cd "$SRC_DIR/build"

    echo "==> Instalando GCC em DESTDIR (prefixo /tools)..."
    make DESTDIR="$DESTDIR" install

    # Agora precisamos gerar o limits.h interno completo, como o LFS faz.
    echo "==> Gerando limits.h interno para o cross-compiler..."

    cd "$SRC_DIR"   # volta para o topo das fontes do gcc

    if [[ -z "${LFS_TGT:-}" ]]; then
        echo "ERRO: LFS_TGT não definido; não consigo localizar libgcc."
        exit 1
    fi

    # Usamos o gcc recém-instalado dentro do DESTDIR, mas o caminho de libgcc
    # que ele imprime é /tools/..., então prefixamos com DESTDIR.
    local cc libgcc_file libgcc_dir

    cc="$DESTDIR/tools/bin/${LFS_TGT}-gcc"
    if [[ ! -x "$cc" ]]; then
        echo "ERRO: não encontrei $cc (cross-compiler do GCC Pass 1)."
        exit 1
    fi

    libgcc_file="$("$cc" -print-libgcc-file-name)"
    # libgcc_file deve ser algo como /tools/lib/gcc/$LFS_TGT/15.2.0/libgcc.a
    libgcc_dir="$DESTDIR$(dirname "$libgcc_file")"

    mkdir -pv "$libgcc_dir/include"

    cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
        "$libgcc_dir/include/limits.h"

    echo "==> GCC Pass 1 instalado em $DESTDIR/tools e limits.h gerado."
}
