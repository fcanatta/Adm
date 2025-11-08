#!/usr/bin/env sh
# Verificações e preparação: não há ./configure para headers do kernel

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Falta $1" >&2; exit 1; }; }
for t in make awk sed tar xz; do need "$t"; done
