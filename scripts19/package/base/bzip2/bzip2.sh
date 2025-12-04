#!/usr/bin/env bash
# bzip2-1.0.8.sh

PKG_VERSION="1.0.8"
SRC_URL="https://sourceware.org/pub/bzip2/bzip2-${PKG_VERSION}.tar.gz"
SRC_MD5=""

pkg_build() {
    : "${NUMJOBS:=1}"

    # bzip2 não usa ./configure
    # estamos em $SRC_DIR
    make -j"${NUMJOBS}"

    make PREFIX=/usr DESTDIR="${DESTDIR}" install

    # gerar libs compartilhadas (estilo LFS)
    make -f Makefile-libbz2_so
    mkdir -pv "${DESTDIR}/usr/lib"

    cp -v libbz2.so.* "${DESTDIR}/usr/lib/"
    local sofile
    sofile="$(basename "$(ls libbz2.so.* | head -n1)")"
    ln -svf "$sofile" "${DESTDIR}/usr/lib/libbz2.so"
}
