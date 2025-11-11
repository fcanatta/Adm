#!/usr/bin/env bash
# Ambiente previsível para Binutils
set -Eeuo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

# Evita que LDFLAGS/CPPFLAGS agressivos quebrem o linker
export CFLAGS="${CFLAGS:--O2 -pipe}"
export CXXFLAGS="${CXXFLAGS:--O2 -pipe}"
export CPPFLAGS=
export LDFLAGS="${LDFLAGS:--Wl,-O1}"

# Sugerir gold opcional via var (o builder decide usar ou não)
: "${ADM_BINUTILS_ENABLE_GOLD:=1}"; export ADM_BINUTILS_ENABLE_GOLD

echo "[hook binutils] flags set (ADM_BINUTILS_ENABLE_GOLD=$ADM_BINUTILS_ENABLE_GOLD)"
