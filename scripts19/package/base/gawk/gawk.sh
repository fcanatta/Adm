#!/usr/bin/env bash
# gawk-5.3.2.sh

PKG_VERSION="5.3.2"
SRC_URL="https://ftp.gnu.org/gnu/gawk/gawk-${PKG_VERSION}.tar.xz"
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

    # garantir awk -> gawk
    mkdir -pv "${DESTDIR}/usr/bin"
    if [[ -x "${DESTDIR}/usr/bin/gawk" && ! -e "${DESTDIR}/usr/bin/awk" ]]; then
      ln -svf gawk "${DESTDIR}/usr/bin/awk"
    fi
}
