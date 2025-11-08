#!/usr/bin/env sh
set -eu
: "${DESTDIR:=/}"
rm -f "${DESTDIR}/usr/include/.adm-kheaders-stage2.meta" 2>/dev/null || true
exit 0
