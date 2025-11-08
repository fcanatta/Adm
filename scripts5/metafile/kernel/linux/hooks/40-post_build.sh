#!/usr/bin/env sh
# Compila o kernel + módulos

set -eu
: "${SRC_DIR:?}"
: "${BUILD_DIR:?}"

O="$(cat "${BUILD_DIR}/.kbuild_O" 2>/dev/null || echo "$SRC_DIR")"
# Kernel
make O="$O" ${ADM_KERNEL_IMAGE:-bzImage}
# Módulos
make O="$O" modules

# Guarda kernelrelease para a instalação
make O="$O" -s kernelrelease > "${BUILD_DIR}/.kernelrelease"
