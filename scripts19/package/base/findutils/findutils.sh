#!/usr/bin/env bash
# findutils-4.10.0.sh

PKG_VERSION="4.10.0"
SRC_URL="https://ftp.gnu.org/gnu/findutils/findutils-${PKG_VERSION}.tar.xz"
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
