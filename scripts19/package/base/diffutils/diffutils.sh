#!/usr/bin/env bash
# diffutils-3.12.sh

PKG_VERSION="3.12"
SRC_URL="https://ftp.gnu.org/gnu/diffutils/diffutils-${PKG_VERSION}.tar.xz"
SRC_MD5=""

pkg_build() {
    : "${NUMJOBS:=1}"

    rm -rf build
    mkdir -v build
    cd build

    ../configure \
        --prefix=/usr

    make -j"${NUMJOBS}"
    make DESTDIR="${DESTDIR}" install
}
