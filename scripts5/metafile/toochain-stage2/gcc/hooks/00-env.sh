#!/usr/bin/env sh
# GCC final nativo (C e C++), instalando em /usr

set -eu
: "${PREFIX:=/usr}"
: "${DESTDIR:=/}"
export PREFIX DESTDIR

# Reprodutibilidade e paralelismo
: "${MAKEFLAGS:=-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
: "${SOURCE_DATE_EPOCH:=1704067200}"
export MAKEFLAGS SOURCE_DATE_EPOCH LC_ALL=C

# Toolchain
: "${CC:=cc}"
: "${CXX:=c++}"
: "${CFLAGS:=-O2 -pipe}"
: "${CXXFLAGS:=${CFLAGS}}"
: "${LDFLAGS:=}"
export CC CXX CFLAGS CXXFLAGS LDFLAGS

# Linguagens: C e C++
: "${ADM_GCC_LANGS:=c,c++}"
export ADM_GCC_LANGS

# Se quiser usar as libs de sistema já instaladas (gmp/mpfr/mpc/isl),
# deixe ADM_GCC_VENDOR_LIBS=0. Se quiser "vender" dos tarballs, use 1.
: "${ADM_GCC_VENDOR_LIBS:=1}"   # 1=vincula diretórios gmp/mpfr/mpc/isl dentro de gcc/
export ADM_GCC_VENDOR_LIBS
