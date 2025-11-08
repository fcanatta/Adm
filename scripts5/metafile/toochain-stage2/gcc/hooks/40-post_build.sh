#!/usr/bin/env sh
# Compilação completa do GCC final

set -eu
: "${BUILD_DIR:?}"

make -C "${BUILD_DIR}" -j"${MAKEFLAGS#-j}" || make -C "${BUILD_DIR}"
