#!/usr/bin/env bash
# pre_build: db-5.3.28 (Berkeley DB)
# - build out-of-tree em ./build_unix
# - roda ../dist/configure com prefixo /usr e shared

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build_unix"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[db/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

PROFILE="${ADM_PROFILE:-normal}"

case "${PROFILE}" in
    aggressive)
        export CFLAGS="${CFLAGS:-} -O3 -pipe"
        ;;
    minimal)
        export CFLAGS="${CFLAGS:-} -O2 -pipe"
        ;;
    *)
        export CFLAGS="${CFLAGS:-} -O2 -pipe"
        ;;
esac

echo "[db/pre_build] Configurando Berkeley DB (profile=${PROFILE})."

../dist/configure \
  --prefix=/usr \
  --enable-compat185 \
  --enable-dbm \
  --enable-cxx \
  --enable-shared \
  --disable-static

echo "[db/pre_build] configure concluído."
