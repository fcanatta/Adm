#!/usr/bin/env sh
# Nada crítico aqui; garantimos .mozconfig visível para o mach

set -eu

: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"

[ -f "$BUILD_DIR/.mozconfig" ] || { echo ".mozconfig ausente em $BUILD_DIR" >&2; exit 1; }

# Algumas versões do mach preferem .mozconfig no SRC_DIR; criamos link simbólico
[ -f "$SRC_DIR/.mozconfig" ] || ln -s "$BUILD_DIR/.mozconfig" "$SRC_DIR/.mozconfig" 2>/dev/null || true
