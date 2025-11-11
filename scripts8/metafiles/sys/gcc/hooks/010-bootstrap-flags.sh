#!/usr/bin/env bash
# Flags estáveis para GCC stage1/stage2
set -Eeuo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

# Stage1 (sem libs) — mais conservador
export BOOT_CFLAGS="${BOOT_CFLAGS:--O2 -pipe}"
# Alvo (libgcc, libstdc++): moderado e previsível
export CFLAGS_FOR_TARGET="${CFLAGS_FOR_TARGET:--O2 -pipe}"
export CXXFLAGS_FOR_TARGET="${CXXFLAGS_FOR_TARGET:--O2 -pipe}"
# Evita LTO no bootstrap
export LTO_BOOTSTRAP="${LTO_BOOTSTRAP:-0}"

# Se o target veio do 90-bootstrap-toolchain, respeite; não force CC host
: "${TARGET:=}"; if [[ -n "${TARGET}" ]]; then
  export AR_FOR_TARGET="${AR_FOR_TARGET:-${TARGET}-ar}"
  export RANLIB_FOR_TARGET="${RANLIB_FOR_TARGET:-${TARGET}-ranlib}"
fi

echo "[hook gcc] BOOT_CFLAGS=$BOOT_CFLAGS LTO_BOOTSTRAP=$LTO_BOOTSTRAP TARGET=${TARGET:-host}"
