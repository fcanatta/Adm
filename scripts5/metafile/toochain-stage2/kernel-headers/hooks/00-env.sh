#!/usr/bin/env sh
# Ambiente para instalar headers no sistema final (stage2)

set -eu
: "${DESTDIR:=/}"         # instala diretamente em /usr/include
: "${PREFIX:=/usr}"
: "${MAKEFLAGS:=-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
: "${SOURCE_DATE_EPOCH:=1704067200}"
export DESTDIR PREFIX MAKEFLAGS SOURCE_DATE_EPOCH LC_ALL=C
