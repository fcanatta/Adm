#!/usr/bin/env sh
# Ambiente p/ Firefox (ESR) com PGO/LTO e sandbox opcionais

set -eu

: "${PREFIX:=/usr}"
: "${DESTDIR:=/}"
export PREFIX DESTDIR

# Reprodutibilidade e paralelismo
: "${MAKEFLAGS:=-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
: "${SOURCE_DATE_EPOCH:=1704067200}"
export MAKEFLAGS SOURCE_DATE_EPOCH LC_ALL=C

# Toolchain preferido
if command -v clang >/dev/null 2>&1; then
  : "${CC:=clang}"; : "${CXX:=clang++}"
  if command -v ld.lld >/dev/null 2>&1; then : "${LD:=ld.lld}"; : "${MOZ_LD:=lld}"; else : "${LD:=ld}"; : "${MOZ_LD:=}"; fi
else
  : "${CC:=gcc}"; : "${CXX:=g++}"; : "${LD:=ld}"; : "${MOZ_LD:=}"
fi
export CC CXX LD MOZ_LD

# Flags básicas
: "${CFLAGS:=-O2 -pipe}"
: "${CXXFLAGS:=${CFLAGS}}"
: "${LDFLAGS:=}"
export CFLAGS CXXFLAGS LDFLAGS

# Ferramentas do mach
: "${PYTHON:=python3}"
: "${NODEJS:=node}"
export PYTHON NODEJS

# ======== Recursos avançados ========
# LTO: "thin" (recomendado), "full" (mais pesado) ou "" (desligado)
: "${ADM_FIREFOX_LTO:=thin}"         # valores: thin|full|""
# PGO: 0 (off) | 1 (duas fases: generate/use)
: "${ADM_FIREFOX_PGO:=0}"
# Tempo máximo em minutos de execução do profile server (PGO)
: "${ADM_FIREFOX_PGO_TIMEOUT:=10}"
# Wayland por padrão no wrapper?
: "${ADM_FIREFOX_ENABLE_WAYLAND:=0}"
# Branding
: "${ADM_FIREFOX_BRANDING:=browser/branding/unofficial}"
# Extra .mozconfig
: "${ADM_FIREFOX_MOZCONFIG_EXTRA:=}"
# Instalar perfil AppArmor opcional?
: "${ADM_FIREFOX_INSTALL_APPARMOR:=0}"
export ADM_FIREFOX_LTO ADM_FIREFOX_PGO ADM_FIREFOX_PGO_TIMEOUT \
       ADM_FIREFOX_ENABLE_WAYLAND ADM_FIREFOX_BRANDING ADM_FIREFOX_MOZCONFIG_EXTRA \
       ADM_FIREFOX_INSTALL_APPARMOR
