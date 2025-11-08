#!/usr/bin/env sh
# Compila "all-gcc" e "all-target-libgcc" (sem headers)

set -eu
: "${BUILD_DIR:?BUILD_DIR não definido}"

# Alguns fluxos compilam no BUILD_DIR direto (out-of-tree)
# O seu adm-build.sh já faz ./configure no BUILD_DIR, então usamos make no BUILD_DIR.
make -C "$BUILD_DIR" all-gcc
make -C "$BUILD_DIR" all-target-libgcc
