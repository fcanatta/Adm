#!/usr/bin/env bash

# Pacote: GCC-15.2.0 (toolchain final)
# Categoria: core
# Nome: gcc
#
# Este é o GCC final (não o pass1).
# Instala em /usr dentro do ROOTFS (via DESTDIR do ADM).
#
# Requer:
#   - Glibc 2.42 já instalada no ROOTFS
#   - Binutils final no ROOTFS
#   - linux-api-headers no ROOTFS/usr/include
#   - gmp, mpfr, mpc, zlib no ROOTFS (/usr/{include,lib})

PKG_NAME="gcc"
PKG_CATEGORY="core"
PKG_VERSION="15.2.0"
PKG_DESC="GNU Compiler Collection ${PKG_VERSION} (C/C++ final)"
PKG_HOMEPAGE="https://gcc.gnu.org/"

# Tarball oficial do GCC-15.2.0 0
PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
)

# SHA512 oficial do gcc-15.2.0.tar.xz (do sha512.sum) 1
PKG_CHECKSUM_TYPE="sha512"
PKG_CHECKSUMS=(
    "89047a2e07bd9da265b507b516ed3635adb17491c7f4f67cf090f0bd5b3fc7f2ee6e4cc4008beef7ca884b6b71dffe2bb652b21f01a702e17b468cca2d10b2de"
)

# Dependências lógicas (ajuste os nomes para bater com os pacotes do ADM)
PKG_DEPENDS=(
    "glibc"
    "binutils"
    "zlib"
    "gmp"
    "mpfr"
    "mpc"
)

pkg_build() {
    : "${SRC_DIR:?SRC_DIR não definido}"
    : "${BUILD_DIR:?BUILD_DIR não definido}"
    : "${ROOTFS:?ROOTFS não definido (ver profile)}"

    echo ">>> [gcc] ROOTFS=${ROOTFS}"
    echo ">>> [gcc] SRC_DIR=${SRC_DIR}"
    echo ">>> [gcc] BUILD_DIR=${BUILD_DIR}"

    cd "$SRC_DIR"

    # LFS: em x86_64, muda lib64 -> lib em t-linux64 2
    case "$(uname -m)" in
        x86_64)
            sed -e '/m64=/s/lib64/lib/' \
                -i.orig gcc/config/i386/t-linux64
            ;;
    esac

    # Diretório de build dedicado
    mkdir -pv "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Configuração baseada em LFS 8.30 GCC-15.2.0 (ajustada) 
    #
    # Observações:
    #  - --prefix=/usr            → GCC final em /usr
    #  - --enable-languages=c,c++ → apenas C e C++
    #  - --enable-default-pie/ssp → hardening padrão
    #  - --disable-multilib       → sem libs 32-bit
    #  - --disable-bootstrap      → sem bootstrap de 3 estágios
    #  - --disable-fixincludes    → não "consertar" headers de sistema
    #  - --with-system-zlib       → usar zlib do sistema
    #
    # Se você estiver cross-compilando com sysroot externo, use PATH,
    # CC, CXX, AR, RANLIB e LD ajustados fora daqui com os binários
    # do toolchain final.

    ../configure \
        --prefix=/usr            \
        LD=ld                    \
        --enable-languages=c,c++ \
        --enable-default-pie     \
        --enable-default-ssp     \
        --enable-host-pie        \
        --disable-multilib       \
        --disable-bootstrap      \
        --disable-fixincludes    \
        --with-system-zlib

    # Compila
    make -j"${ADM_JOBS:-$(nproc)}"
}

pkg_install() {
    : "${BUILD_DIR:?BUILD_DIR não definido}"
    : "${DESTDIR:?DESTDIR não definido}"
    : "${CHOST:?CHOST não definido (ver profile)}"

    cd "$BUILD_DIR"

    # Instala no DESTDIR (ADM depois sincroniza DESTDIR -> ROOTFS)
    make DESTDIR="$DESTDIR" install

    # Ajusta ownership de headers para root:root (LFS) 
    local gcc_inc_dir="$DESTDIR/usr/lib/gcc/${CHOST}/${PKG_VERSION}/include"
    local gcc_inc_fix="$DESTDIR/usr/lib/gcc/${CHOST}/${PKG_VERSION}/include-fixed"
    if [[ -d "$gcc_inc_dir" ]]; then
        chown -v -R root:root "$gcc_inc_dir"
    fi
    if [[ -d "$gcc_inc_fix" ]]; then
        chown -v -R root:root "$gcc_inc_fix"
    fi

    # Symlink histórico exigido pelo FHS: /usr/lib/cpp → /usr/bin/cpp 
    mkdir -pv "$DESTDIR/usr/lib"
    ln -svf ../bin/cpp "$DESTDIR/usr/lib/cpp"

    # Manpage cc.1 → gcc.1 (cc já deve ser symlink para gcc) 
    mkdir -pv "$DESTDIR/usr/share/man/man1"
    if [[ -f "$DESTDIR/usr/share/man/man1/gcc.1" ]]; then
        ln -svf gcc.1 "$DESTDIR/usr/share/man/man1/cc.1"
    fi

    # Symlink para liblto_plugin.so em /usr/lib/bfd-plugins/ (LTO) 
    mkdir -pv "$DESTDIR/usr/lib/bfd-plugins"
    local lto_src="$DESTDIR/usr/libexec/gcc/${CHOST}/${PKG_VERSION}/liblto_plugin.so"
    local lto_dst="$DESTDIR/usr/lib/bfd-plugins/liblto_plugin.so"
    if [[ -f "$lto_src" ]]; then
        ln -sfv "../../libexec/gcc/${CHOST}/${PKG_VERSION}/liblto_plugin.so" "$lto_dst"
    fi
}
