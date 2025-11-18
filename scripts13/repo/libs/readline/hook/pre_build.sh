#!/usr/bin/env bash
# pre_build: readline
# - build out-of-tree em ./build
# - link contra ncursesw (wide char) em /usr

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[readline/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

echo "[readline/pre_build] Configurando readline com ncursesw."

# Garante headers do ncurses widec
export CPPFLAGS="-I/usr/include/ncursesw ${CPPFLAGS:-}"
export LDFLAGS="-L/usr/lib ${LDFLAGS:-}"

../configure \
  --prefix=/usr \
  --disable-static \
  --with-curses

echo "[readline/pre_build] configure concluído."
