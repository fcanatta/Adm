#!/usr/bin/env sh
# Compila a libstdc++

set -eu
: "${SRC_DIR:?}"
: "${BUILD_DIR:?}"

# Constrói apenas libstdc++-v3 (no out-of-tree)
# O seu adm-build.sh chama ./configure no BUILD_DIR com os args acima.
make -C "${BUILD_DIR}" -j"${MAKEFLAGS#-j}" || make -C "${BUILD_DIR}"
