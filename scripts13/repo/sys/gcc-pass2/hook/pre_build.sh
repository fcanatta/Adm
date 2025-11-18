# /usr/src/adm/repo/sys/gcc-pass2/hook/pre_build.sh
#!/usr/bin/env bash
# pre_build: gcc pass 2 (toolchain final, C/C++ sobre glibc/musl)

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[gcc-pass2/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

default_target="$(uname -m)-lfs-linux-gnu"
TARGET="${ADM_TARGET:-${LFS_TGT:-$default_target}}"

if command -v ../config.guess >/dev/null 2>&1; then
    BUILD_TRIPLE="$(../config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
else
    BUILD_TRIPLE="$(uname -m)-unknown-linux-gnu"
fi

echo "[gcc-pass2/pre_build] Configurando GCC (pass2) para:"
echo "  build=${BUILD_TRIPLE} host=${TARGET} target=${TARGET}"

GMP_PREFIX="${GMP_PREFIX:-/usr}"
MPFR_PREFIX="${MPFR_PREFIX:-/usr}"
MPC_PREFIX="${MPC_PREFIX:-/usr}"
ISL_PREFIX="${ISL_PREFIX:-/usr}"

../configure \
  --build="${BUILD_TRIPLE}" \
  --host="${TARGET}" \
  --target="${TARGET}" \
  --prefix=/usr \
  --with-sysroot=/ \
  --with-gmp="${GMP_PREFIX}" \
  --with-mpfr="${MPFR_PREFIX}" \
  --with-mpc="${MPC_PREFIX}" \
  --with-isl="${ISL_PREFIX}" \
  --enable-languages=c,c++ \
  --enable-shared \
  --enable-threads=posix \
  --enable-__cxa_atexit \
  --enable-clocale=gnu \
  --enable-lto \
  --disable-multilib \
  --disable-werror

echo "[gcc-pass2/pre_build] configure concluído."
