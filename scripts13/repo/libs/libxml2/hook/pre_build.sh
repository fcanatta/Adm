#!/usr/bin/env bash
# pre_build: libxml2
# - desativa bindings Python
# - usa zlib do sistema
# - build out-of-tree

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[libxml2/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

export CPPFLAGS="${CPPFLAGS:-} -I/usr/include"
export LDFLAGS="${LDFLAGS:-} -L/usr/lib"

echo "[libxml2/pre_build] Configurando libxml2."

../configure \
  --prefix=/usr \
  --disable-static \
  --enable-shared \
  --with-zlib=/usr \
  --without-python \
  --without-lzma

echo "[libxml2/pre_build] configure concluído."
