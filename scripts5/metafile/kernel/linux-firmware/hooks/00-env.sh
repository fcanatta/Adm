#!/usr/bin/env sh
# Ambiente para instalar firmwares

set -eu
: "${DESTDIR:=/}"
: "${FW_DEST:=/lib/firmware}"
: "${MAKEFLAGS:=-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
: "${SOURCE_DATE_EPOCH:=1704067200}"
# Filtro opcional (globs separados por espaço): ex "iwlwifi* amdgpu/* radeon/* brcm/*"
: "${ADM_FIRMWARE_FILTER:=}"    # vazio = instala tudo
export DESTDIR FW_DEST MAKEFLAGS SOURCE_DATE_EPOCH ADM_FIRMWARE_FILTER LC_ALL=C
