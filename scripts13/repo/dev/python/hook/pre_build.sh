#!/usr/bin/env bash
# pre_build: python 3.14.0
# - build out-of-tree
# - integra libffi / openssl / sqlite / readline do sistema

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[python/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

PROFILE="${ADM_PROFILE:-normal}"

# inclui headers e libs padrões
export CPPFLAGS="${CPPFLAGS:-} -I/usr/include"
export LDFLAGS="${LDFLAGS:-} -L/usr/lib"
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-/usr/lib/pkgconfig:/usr/share/pkgconfig}"

# garante headers específicos
export CPPFLAGS="${CPPFLAGS} -I/usr/include/ffi -I/usr/include/openssl"
# sqlite quase sempre tem sqlite3.h direto em /usr/include

case "${PROFILE}" in
    aggressive)
        export CFLAGS="${CFLAGS:-} -O3 -fno-plt -pipe"
        CONFIG_OPTS="--enable-optimizations --with-lto"
        ;;
    minimal)
        export CFLAGS="${CFLAGS:-} -O2 -pipe"
        CONFIG_OPTS="--disable-test-modules"
        ;;
    *)
        export CFLAGS="${CFLAGS:-} -O2 -pipe"
        CONFIG_OPTS="--enable-optimizations"
        ;;
esac

echo "[python/pre_build] Configurando Python 3.14.0 (profile=${PROFILE})."

../configure \
  --prefix=/usr \
  --enable-shared \
  --with-ensurepip=install \
  --with-system-ffi \
  --with-openssl=/usr \
  --enable-loadable-sqlite-extensions \
  ${CONFIG_OPTS}

echo "[python/pre_build] configure concluído."
