#!/usr/bin/env sh
# Ambiente mínimo para instalar Linux API headers (stage0)

set -eu

: "${LFS:=/mnt/lfs}"
: "${DESTDIR:=$LFS}"          # headers vão para $DESTDIR/usr/include
: "${PREFIX:=$LFS/usr}"
: "${MAKEFLAGS:=-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
: "${SOURCE_DATE_EPOCH:=1704067200}"
export LFS DESTDIR PREFIX MAKEFLAGS SOURCE_DATE_EPOCH LC_ALL=C
