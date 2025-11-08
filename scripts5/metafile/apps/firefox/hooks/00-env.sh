#!/usr/bin/env sh
# Ambiente padrão para build do Firefox (ESR)

set -eu

# Prefixo e instalação
: "${PREFIX:=/usr}"
: "${DESTDIR:=/}"
export PREFIX DESTDIR

# Paralelismo e reprodutibilidade
: "${MAKEFLAGS:=-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
: "${SOURCE_DATE_EPOCH:=1704067200}"  # 2024-01-01 UTC
export MAKEFLAGS SOURCE_DATE_EPOCH LC_ALL=C

# Toolchain preferencial: clang/lld se existirem; fallback p/ gcc/binutils
if command -v clang >/dev/null 2>&1; then
  : "${CC:=clang}"
  : "${CXX:=clang++}"
  if command -v ld.lld >/dev/null 2>&1; then
    : "${LD:=ld.lld}"
    : "${MOZ_LD:=lld}"
  else
    : "${LD:=ld}"
    : "${MOZ_LD:=}"
  fi
else
  : "${CC:=gcc}"
  : "${CXX:=g++}"
  : "${LD:=ld}"
  : "${MOZ_LD:=}"
fi
export CC CXX LD MOZ_LD

# Flags conservadoras (otimização sem exagero; PGO/LTO fora por simplicidade)
: "${CFLAGS:=-O2 -pipe}"
: "${CXXFLAGS:=${CFLAGS}}"
: "${LDFLAGS:=}"
export CFLAGS CXXFLAGS LDFLAGS

# Python e Node necessários pelo 'mach'
: "${PYTHON:=python3}"
: "${NODEJS:=node}"
export PYTHON NODEJS

# Opções adicionais via variáveis do pipeline (podem vir vazias)
: "${ADM_FIREFOX_ENABLE_WAYLAND:=0}"     # 1 = exporta MOZ_ENABLE_WAYLAND=1 no wrapper
: "${ADM_FIREFOX_BRANDING:=browser/branding/unofficial}"  # evite 'official' por licença/marca
: "${ADM_FIREFOX_MOZCONFIG_EXTRA:=}"     # linha(s) extras para .mozconfig
export ADM_FIREFOX_ENABLE_WAYLAND ADM_FIREFOX_BRANDING ADM_FIREFOX_MOZCONFIG_EXTRA
