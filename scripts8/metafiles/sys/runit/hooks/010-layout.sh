#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
mkdir -p "${DESTDIR}/etc/runit/runsvdir/default" "${DESTDIR}/etc/runit/sv"
echo "[runit] layout base criado"
