#!/usr/bin/env bash
# Hook pre_build para glibc:
# - prepara build out-of-tree em ./build
# - roda ../configure com opções de cross

set -euo pipefail

# Diretório do source (onde está o configure da glibc)
: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

# Diretório de build out-of-tree
BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[glibc/pre_build] glibc já configurada em '${BUILD_DIR}', pulando."
    exit 0
fi

# Detecta target e build
default_target="$(uname -m)-lfs-linux-gnu"
TARGET="${ADM_TARGET:-${LFS_TGT:-$default_target}}"

if command -v ../scripts/config.guess >/dev/null 2>&1; then
    BUILD_TRIPLE="$(../scripts/config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
else
    BUILD_TRIPLE="$(uname -m)-unknown-linux-gnu"
fi

echo "[glibc/pre_build] Configurando glibc para:"
echo "  build = ${BUILD_TRIPLE}"
echo "  host  = ${TARGET}"
echo "  target= ${TARGET}"

# Cabeçalho do kernel já deve estar em /usr/include dentro do (ch)root
HEADERS_DIR="${GLIBC_HEADERS_DIR:-/usr/include}"

# Alguns tunings padrão de LFS, ajusta se quiser
../configure \
  --prefix=/usr \
  --host="${TARGET}" \
  --build="${BUILD_TRIPLE}" \
  --enable-kernel=4.19 \
  --with-headers="${HEADERS_DIR}" \
  libc_cv_slibdir=/usr/lib

echo "[glibc/pre_build] configure concluído em '${BUILD_DIR}'."
