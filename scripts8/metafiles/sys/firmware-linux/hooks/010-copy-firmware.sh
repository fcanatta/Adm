#!/usr/bin/env bash
set -Eeuo pipefail

: "${DESTDIR:=/}"

mkdir -p "${DESTDIR}/usr/lib/firmware"

# Copia tudo
cp -a ./* "${DESTDIR}/usr/lib/firmware/" 2>/dev/null || true

echo "[firmware] Instalado em /usr/lib/firmware"
