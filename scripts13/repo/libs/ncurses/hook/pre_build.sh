#!/usr/bin/env bash
# pre_build: ncurses (wide-char, sem static, terminfo em /usr/share/terminfo)

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[ncurses/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

echo "[ncurses/pre_build] Configurando ncurses (wide-char, shared only)."

../configure \
  --prefix=/usr \
  --mandir=/usr/share/man \
  --with-shared \
  --without-debug \
  --without-normal \
  --with-termlib \
  --enable-widec \
  --enable-pc-files \
  --with-pkg-config-libdir=/usr/lib/pkgconfig \
  --with-terminfo-dirs=/usr/share/terminfo

echo "[ncurses/pre_build] configure concluído."
