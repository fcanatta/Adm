#!/usr/bin/env bash
# file-5.46.sh

PKG_VERSION="5.46"
SRC_URL="https://astron.com/pub/file/file-${PKG_VERSION}.tar.gz"
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
