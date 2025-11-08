#!/usr/bin/env sh
# Ambiente mínimo para stage0 (headers apenas)

set -eu

: "${LFS:=/mnt/lfs}"
: "${PREFIX:=$LFS/tools}"     # stage0 instala cabeçalhos destinados ao toolchain
: "${DESTDIR:=$LFS}"          # musl install-headers respeita DESTDIR
: "${MAKEFLAGS:=-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
: "${SOURCE_DATE_EPOCH:=1704067200}"
export LFS PREFIX DESTDIR MAKEFLAGS SOURCE_DATE_EPOCH LC_ALL=C
