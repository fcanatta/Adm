#!/usr/bin/env sh
# Limpeza pós-uninstall: não mexe fora do PREFIX

set -eu

: "${PREFIX:?PREFIX não definido}"

# Se desejar, remova metadados auxiliares
rm -f "${PREFIX}/.adm-binutils-stage2.meta" 2>/dev/null || true
exit 0
