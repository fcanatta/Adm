#!/usr/bin/env sh
# Limpeza suave: remove apenas metadados/symlinks genéricos criados por este hook

set -eu
: "${SYSLIBDIR:=/lib}"
: "${DESTDIR:=/}"

rm -f "$DESTDIR$SYSLIBDIR/ld-musl.so.1" 2>/dev/null || true
rm -f "$DESTDIR$SYSLIBDIR/.adm-musl-stage2.meta" 2>/dev/null || true

# Arquivos principais (ld-musl-*.so.1, libc.so, etc.) serão tratados pelo uninstall via manifest.
exit 0
