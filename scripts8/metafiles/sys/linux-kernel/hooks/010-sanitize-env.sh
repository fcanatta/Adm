#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

# Evitar flags agressivas
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

# Build directory separado
: "${KBUILD_OUTPUT:=build}"
export KBUILD_OUTPUT

echo "[kernel] Sanitização OK (O=${KBUILD_OUTPUT})"
