#!/usr/bin/env sh
# Não removemos diretórios inteiros automaticamente; uninstall via manifest cuida de arquivos.
# Aqui removemos apenas metadados.

set -eu
: "${DESTDIR:=/}"
: "${FW_DEST:=/lib/firmware}"
rm -f "${DESTDIR}${FW_DEST}/.adm-linux-firmware.meta" 2>/dev/null || true
exit 0
