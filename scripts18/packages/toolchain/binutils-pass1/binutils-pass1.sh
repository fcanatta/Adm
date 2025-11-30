# $LFS/packages/toolchain/binutils-pass1/binutils-pass1.sh
#!/usr/bin/env bash

PKG_NAME="binutils-pass1"
PKG_VERSION="2.41"
PKG_CATEGORY="toolchain"
PKG_DEPS=()   # se quisesse dependência, ex: PKG_DEPS=(zlib)

pkg_build() {
    set -euo pipefail

    : "${LFS:?LFS não definido}"
    : "${LFS_TGT:?LFS_TGT não definido (ex: x86_64-lfs-linux-gnu)}"

    local SRC_DIR="$LFS/sources"
    local TARBALL="binutils-2.41.tar.xz"
    local PKG_DIR="binutils-2.41"

    cd "$SRC_DIR"
    rm -rf "$PKG_DIR"
    tar -xf "$TARBALL"
    cd "$PKG_DIR"

    mkdir -v build
    cd build

    ../configure \
        --prefix="$LFS/tools" \
        --with-sysroot="$LFS" \
        --target="$LFS_TGT"   \
        --disable-nls         \
        --enable-gprofng=no   \
        --disable-werror

    make -j"$(nproc)"
    make install

    cd "$SRC_DIR"
    rm -rf "$PKG_DIR"
}
