#!/usr/bin/env bash
# pre_build: pcre2
# - build out-of-tree em ./build
# - ativa UTF/Unicode, libs compartilhadas

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[pcre2/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

echo "[pcre2/pre_build] Configurando pcre2 (UTF, Unicode, shared)."

../configure \
  --prefix=/usr \
  --enable-pcre2-16 \
  --enable-pcre2-32 \
  --enable-unicode \
  --enable-jit \
  --enable-pcre2grep-libbz2 \
  --enable-pcre2grep-libz \
  --disable-static

echo "[pcre2/pre_build] configure concluído."
