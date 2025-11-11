#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"

mkdir -p "${DESTDIR}${PREFIX}/bin"
cp -a obj/dist/bin/* "${DESTDIR}${PREFIX}/bin/"

echo "[FIREFOX] Instalação concluída"
