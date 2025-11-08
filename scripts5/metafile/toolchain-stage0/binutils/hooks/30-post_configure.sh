#!/usr/bin/env sh
# Ajustes finos pós-configure (opcional)

set -eu

: "${BUILD_DIR:?BUILD_DIR não definido}"
cd "$BUILD_DIR"

# Evita timestamps instáveis em ar/ranlib (já coberto por SOURCE_DATE_EPOCH,
# mas reforçamos para versões antigas)
: "${ARFLAGS:=crD}"
export ARFLAGS
