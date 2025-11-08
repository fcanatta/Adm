#!/usr/bin/env sh
# Garantir diretórios e ferramentas para instalar headers

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
mkdir -p "$BUILD_DIR" || true

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Falta $1" >&2; exit 1; }; }
for t in make awk sed tar gzip; do need "$t"; done

# Nada de ./configure nesta fase; headers são instalados direto via 'make install-headers'
