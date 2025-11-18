# /usr/src/adm/repo/sys/binutils-pass1/hook/pre_build.sh
#!/usr/bin/env bash
# pre_build: binutils pass 1 (cross-only)

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[binutils-pass1/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

default_target="$(uname -m)-lfs-linux-gnu"
TARGET="${ADM_TARGET:-${LFS_TGT:-$default_target}}"

echo "[binutils-pass1/pre_build] Configurando binutils (pass1) para target='${TARGET}'."

../configure \
  --target="${TARGET}" \
  --prefix=/usr \
  --with-sysroot=/ \
  --disable-nls \
  --disable-werror

echo "[binutils-pass1/pre_build] configure concluído."
