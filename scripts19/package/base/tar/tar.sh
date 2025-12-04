#!/usr/bin/env bash
# tar-1.35.sh

PKG_VERSION="1.35"
SRC_URL="https://ftp.gnu.org/gnu/tar/tar-${PKG_VERSION}.tar.xz"
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
