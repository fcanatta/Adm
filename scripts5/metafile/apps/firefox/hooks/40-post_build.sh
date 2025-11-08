#!/usr/bin/env sh
# Compila usando ./mach (respeita .mozconfig)

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${PYTHON:?}"

cd "$SRC_DIR"

# Evita uso de rede durante o build
export MOZ_OFFICIAL=1
export MOZBUILD_STATE_PATH="${BUILD_DIR}/.mozstate"
mkdir -p "$MOZBUILD_STATE_PATH" || true

# Compilar
"$PYTHON" ./mach build || {
  echo "[ERROR] mach build falhou" >&2
  exit 1
}

# Guarda local do produto para a etapa de instalação
# Em geral, ./mach coloca artefatos em objdir/dist
echo "$BUILD_DIR/dist" > "$BUILD_DIR/.distdir"
