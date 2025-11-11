#!/usr/bin/env bash
# Torna o configure/build da glibc previsível
set -Eeuo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

# Evita arrastar flags host; glibc é sensível
export CFLAGS="${CFLAGS:--O2 -pipe}"
export CXXFLAGS="${CXXFLAGS:--O2 -pipe}"
export CPPFLAGS=
export LDFLAGS=

# Build/host/target são comandados pelo 90-bootstrap-toolchain; não force aqui.
: "${TARGET:=}"; : "${SYSROOT:=}"
if [[ -n "${SYSROOT}" ]]; then
  export sysheaders="$SYSROOT/usr/include"
fi

echo "[hook glibc] flags limpas; LC_ALL=C; sysheaders=${sysheaders:-n/a}"
