#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"

# Instalador oficial do Rust aceita --prefix e --destdir
find . -maxdepth 2 -type f -name 'install.sh' -exec bash {} --prefix="${PREFIX}" --destdir="${DESTDIR}" \;
echo "[rust] instalado (bootstrap binário)"
