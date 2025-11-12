#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"; : "${PREFIX:=/usr}"
src_dir="$(find . -maxdepth 1 -type d -name 'node-v*' | head -n1 || true)"
[[ -n "$src_dir" ]] && cp -a "$src_dir"/. "${DESTDIR}${PREFIX}/" && echo "[nodejs] instalado em ${PREFIX}/"
