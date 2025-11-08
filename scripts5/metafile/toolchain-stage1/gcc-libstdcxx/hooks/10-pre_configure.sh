#!/usr/bin/env sh
# Prepara build out-of-tree em libstdc++-v3/

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Falta $1" >&2; exit 1; }; }
for t in awk sed make tar xz; do need "$t"; done

mkdir -p "$BUILD_DIR" || true
