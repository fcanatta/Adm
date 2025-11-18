#!/usr/bin/env bash
# Hook pre_build para musl:
# - aplica build out-of-tree em ./build
# - roda ../configure com target musl para cross
# (patches de segurança já devem ter sido aplicados antes
#  pelo estágio de patch genérico ou outro hook.)

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.mak || -f config.status ]]; then
    echo "[musl/pre_build] musl já configurada em '${BUILD_DIR}', pulando."
    exit 0
fi

# Target default musl: <arch>-lfs-linux-musl
arch="$(uname -m)"
default_target="${arch}-lfs-linux-musl"
TARGET="${ADM_TARGET:-${LFS_TGT:-$default_target}}"

echo "[musl/pre_build] Configurando musl para:"
echo "  target = ${TARGET}"

# Em sistemas LFS/musl típicos:
#  - prefix=/usr
#  - syslibdir=/lib (libs críticas ficam em /lib)
../configure \
  --prefix=/usr \
  --target="${TARGET}" \
  --syslibdir=/lib

echo "[musl/pre_build] configure concluído em '${BUILD_DIR}'."
