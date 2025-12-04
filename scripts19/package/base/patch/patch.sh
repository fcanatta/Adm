#!/usr/bin/env bash
# patch-2.8.sh

PKG_VERSION="2.8"
SRC_URL="https://ftp.gnu.org/gnu/patch/patch-${PKG_VERSION}.tar.xz"
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
