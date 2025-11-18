# /usr/src/adm/repo/sys/binutils-pass2/hook/pre_build.sh
#!/usr/bin/env bash
# pre_build: binutils pass 2 (ajustado contra glibc/musl já instalados)

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[binutils-pass2/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

default_target="$(uname -m)-lfs-linux-gnu"
TARGET="${ADM_TARGET:-${LFS_TGT:-$default_target}}"

if command -v ../config.guess >/dev/null 2>&1; then
    BUILD_TRIPLE="$(../config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
else
    BUILD_TRIPLE="$(uname -m)-unknown-linux-gnu"
fi

echo "[binutils-pass2/pre_build] Configurando binutils (pass2) para:"
echo "  build=${BUILD_TRIPLE} host=${TARGET} target=${TARGET}"

../configure \
  --prefix=/usr \
  --build="${BUILD_TRIPLE}" \
  --host="${TARGET}" \
  --target="${TARGET}" \
  --enable-gold \
  --enable-ld=default \
  --enable-plugins \
  --enable-shared \
  --disable-werror

echo "[binutils-pass2/pre_build] configure concluído."
