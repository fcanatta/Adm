#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

# remover flags agressivas herdadas
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

# diretório do build
: "${KBUILD_OUTPUT:=build}"
export KBUILD_OUTPUT

echo "[kernel performance] Ambiente sanitizado (O=${KBUILD_OUTPUT})"
