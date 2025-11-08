#!/usr/bin/env sh
# Instala libstdc++ e headers

set -eu
: "${BUILD_DIR:?}"
: "${DESTDIR:?}"

make -C "${BUILD_DIR}" DESTDIR="${DESTDIR}" install

# Metadados auxiliares
{
  echo "NAME=gcc-libstdcxx"
  echo "PREFIX=${PREFIX:-/usr}"
  echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${DESTDIR}${PREFIX:-/usr}/lib/.adm-gcc-libstdcxx.meta" 2>/dev/null || true
