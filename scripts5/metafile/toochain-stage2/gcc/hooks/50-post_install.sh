#!/usr/bin/env sh
# Instala o GCC final (binários, libs, specs) e ajusta symlinks úteis

set -eu
: "${BUILD_DIR:?}"
: "${DESTDIR:?}"
: "${PREFIX:?}"

make -C "${BUILD_DIR}" DESTDIR="${DESTDIR}" install

# Alternativas/symlinks gentis (se já não existirem)
for b in gcc g++ cpp gcov; do
  [ -x "${DESTDIR}${PREFIX}/bin/${b}" ] || continue
  : # nada extra – já instalados
done

# Metadados
{
  echo "NAME=gcc"
  echo "PREFIX=${PREFIX}"
  echo "LANGS=${ADM_GCC_LANGS}"
  echo "VENDOR_LIBS=${ADM_GCC_VENDOR_LIBS}"
  echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${DESTDIR}${PREFIX}/lib/gcc/.adm-gcc-stage2.meta" 2>/dev/null || true
