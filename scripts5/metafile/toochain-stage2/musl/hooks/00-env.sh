#!/usr/bin/env sh
# Build nativo completo da musl

set -eu

: "${PREFIX:=/usr}"
: "${DESTDIR:=/}"                        # seu pipeline instalará em raiz via manifest
: "${SYSLIBDIR:=/lib}"                   # musl recomenda bibliotecas em /lib
: "${CFLAGS:=-O2 -pipe}"
: "${MAKEFLAGS:=-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
: "${SOURCE_DATE_EPOCH:=1704067200}"
export PREFIX DESTDIR SYSLIBDIR CFLAGS MAKEFLAGS SOURCE_DATE_EPOCH LC_ALL=C

# Caminhos padrão do dynamic linker
# musl instalará /lib/ld-musl-$(arch).so.1; criaremos symlinks úteis no post_install.
