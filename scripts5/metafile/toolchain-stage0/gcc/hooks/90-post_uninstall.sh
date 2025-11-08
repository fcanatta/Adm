#!/usr/bin/env sh
# Limpeza suave; o uninstall do ADM removerá por manifest o que for necessário.

set -eu
: "${DESTDIR:=/mnt/lfs}"
: "${PREFIX:=${DESTDIR}/tools}"

rm -f "${DESTDIR}${PREFIX}/.adm-gcc-stage0.meta" 2>/dev/null || true
# Não removemos symlinks/dirs agressivamente aqui.
exit 0
