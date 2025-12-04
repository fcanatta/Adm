#!/usr/bin/env bash
# sed-4.9.sh

PKG_VERSION="4.9"
SRC_URL="https://ftp.gnu.org/gnu/sed/sed-${PKG_VERSION}.tar.xz"
SRC_MD5=""

pkg_build() {
    : "${NUMJOBS:=1}"

    # estamos em $SRC_DIR (o adm já fez cd pra cá)
    rm -rf build
    mkdir -v build
    cd build

    ../configure \
        --prefix=/usr

    make -j"${NUMJOBS}"
    make DESTDIR="${DESTDIR}" install
}
