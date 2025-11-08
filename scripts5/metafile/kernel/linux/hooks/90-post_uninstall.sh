#!/usr/bin/env sh
# Limpeza leve: apenas metadados; os arquivos reais são removidos pelo uninstall via manifest

set -eu
: "${DESTDIR:=/}"
# Tentativa de apagar meta(s)
rm -f "$DESTDIR/boot/.adm-linux-*.meta" 2>/dev/null || true
exit 0
