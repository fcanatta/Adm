#!/usr/bin/env sh
# Build apenas da libstdc++ (a partir do tarball do GCC), nativo

set -eu
: "${PREFIX:=/usr}"
: "${DESTDIR:=/}"
: "${MAKEFLAGS:=-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
: "${SOURCE_DATE_EPOCH:=1704067200}"
export PREFIX DESTDIR MAKEFLAGS SOURCE_DATE_EPOCH LC_ALL=C

# Usa o compilador atual do sistema (já funcional após musl stage2)
: "${CC:=cc}"
: "${CXX:=c++}"
: "${CFLAGS:=-O2 -pipe}"
: "${CXXFLAGS:=${CFLAGS}}"
: "${LDFLAGS:=}"
export CC CXX CFLAGS CXXFLAGS LDFLAGS
