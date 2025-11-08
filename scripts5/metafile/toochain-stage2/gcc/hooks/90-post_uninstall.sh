#!/usr/bin/env sh
# Limpeza leve

set -eu
: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"
rm -f "${DESTDIR}${PREFIX}/lib/gcc/.adm-gcc-stage2.meta" 2>/dev/null || true
exit 0
