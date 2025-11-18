#!/usr/bin/env bash
# pre_build: bash (usa readline instalada, /usr como prefixo)

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[bash/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

echo "[bash/pre_build] Configurando bash com readline do sistema."

../configure \
  --prefix=/usr \
  --without-bash-malloc \
  --with-installed-readline

echo "[bash/pre_build] configure concluído."
