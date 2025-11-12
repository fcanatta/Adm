#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
mkdir -p "${DESTDIR}/usr/share/zoneinfo"
# A maior parte dos tarballs já traz diretórios prontos (africa, etc.)
cp -a * "${DESTDIR}/usr/share/zoneinfo/" 2>/dev/null || true
echo "[tzdata] zoneinfo instalado em /usr/share/zoneinfo"
