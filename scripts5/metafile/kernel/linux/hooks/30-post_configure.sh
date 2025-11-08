#!/usr/bin/env sh
# Nada obrigatório; garantimos O consistente
set -eu
: "${BUILD_DIR:?BUILD_DIR não definido}"
[ -s "${BUILD_DIR}/.kbuild_O" ] || exit 0
exit 0
