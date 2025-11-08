#!/usr/bin/env sh
# Desinstalação suave: o uninstall do ADM remove por manifest.
# Aqui só removemos o meta auxiliar, se existir.

set -eu
: "${DESTDIR:=/mnt/lfs}"
rm -f "${DESTDIR}/usr/include/.adm-kheaders-stage0.meta" 2>/dev/null || true
exit 0
