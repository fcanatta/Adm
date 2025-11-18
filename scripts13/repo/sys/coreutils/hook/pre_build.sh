#!/usr/bin/env bash
# pre_build: coreutils (instala em /usr, opções seguras)

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[coreutils/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

echo "[coreutils/pre_build] Configurando coreutils para /usr."

../configure \
  --prefix=/usr \
  --enable-no-install-program=kill,uptime

echo "[coreutils/pre_build] configure concluído."
