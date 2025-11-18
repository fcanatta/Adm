# /usr/src/adm/repo/sys/gcc-pass1/hook/pre_build.sh
#!/usr/bin/env bash
# pre_build: gcc pass 1 (cross, C-only, sem headers)

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[gcc-pass1/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

default_target="$(uname -m)-lfs-linux-gnu"
TARGET="${ADM_TARGET:-${LFS_TGT:-$default_target}}"

if command -v ../config.guess >/dev/null 2>&1; then
    BUILD_TRIPLE="$(../config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
else
    BUILD_TRIPLE="$(uname -m)-unknown-linux-gnu"
fi

echo "[gcc-pass1/pre_build] Configurando GCC (pass1) para:"
echo "  build=${BUILD_TRIPLE} host=${BUILD_TRIPLE} target=${TARGET}"

# Caminhos padrão das libs gmp/mpfr/mpc/isl instaladas em /usr
GMP_PREFIX="${GMP_PREFIX:-/usr}"
MPFR_PREFIX="${MPFR_PREFIX:-/usr}"
MPC_PREFIX="${MPC_PREFIX:-/usr}"
ISL_PREFIX="${ISL_PREFIX:-/usr}"

../configure \
  --build="${BUILD_TRIPLE}" \
  --host="${BUILD_TRIPLE}" \
  --target="${TARGET}" \
  --prefix=/usr \
  --with-sysroot=/ \
  --with-gmp="${GMP_PREFIX}" \
  --with-mpfr="${MPFR_PREFIX}" \
  --with-mpc="${MPC_PREFIX}" \
  --with-isl="${ISL_PREFIX}" \
  --without-headers \
  --with-newlib \
  --enable-languages=c \
  --disable-nls \
  --disable-libatomic \
  --disable-libgomp \
  --disable-libquadmath \
  --disable-libssp \
  --disable-libvtv \
  --disable-multilib \
  --disable-shared \
  --disable-threads

echo "[gcc-pass1/pre_build] configure concluído."
