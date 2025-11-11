#!/usr/bin/env bash
# Sanitiza ambiente p/ headers do kernel
set -Eeuo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

# Evita flags agressivas do host afetarem "make headers"
export CFLAGS= CXXFLAGS= CPPFLAGS= LDFLAGS=
# Define ARCH coerente (pode ser sobreposto pelo builder)
: "${ARCH:=$(uname -m)}"; export ARCH

echo "[hook linux-headers] LC_ALL=$LC_ALL ARCH=$ARCH (flags limpas)"
