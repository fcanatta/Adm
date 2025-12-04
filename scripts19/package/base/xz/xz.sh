#!/usr/bin/env bash
# xz-5.8.1.sh

PKG_VERSION="5.8.1"
SRC_URL="https://tukaani.org/xz/xz-${PKG_VERSION}.tar.xz"
SRC_MD5=""

pkg_build() {
    : "${NUMJOBS:=1}"

    rm -rf build
    mkdir -v build
    cd build

    ../configure \
        --prefix=/usr \
        --disable-static

    make -j"${NUMJOBS}"
    make DESTDIR="${DESTDIR}" install
}
