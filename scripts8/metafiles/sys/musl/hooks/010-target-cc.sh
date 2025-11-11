#!/usr/bin/env bash
# Garante que o compilador alvo é usado ao construir a musl
set -Eeuo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

: "${TARGET:=}"; : "${SYSROOT:=}"
if [[ -n "${TARGET}" ]]; then
  export CC="${CC:-${TARGET}-gcc}"
  export AR="${AR:-${TARGET}-ar}"
  export RANLIB="${RANLIB:-${TARGET}-ranlib}"
fi
export CFLAGS="${CFLAGS:--O2 -pipe}"

echo "[hook musl] CC=$CC (TARGET=${TARGET:-host})"
