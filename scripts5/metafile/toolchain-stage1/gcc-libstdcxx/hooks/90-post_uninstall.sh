#!/usr/bin/env sh
# Limpeza leve

set -eu
: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"
rm -f "${DESTDIR}${PREFIX}/lib/.adm-gcc-libstdcxx.meta" 2>/dev/null || true
exit 0
