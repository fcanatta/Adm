#!/usr/bin/env sh
# Instala o compilador e o libgcc para o target dentro do sysroot

set -eu
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${DESTDIR:?DESTDIR não definido}"
: "${PREFIX:?PREFIX não definido}"

# Instala binários do gcc cross
make -C "$BUILD_DIR" DESTDIR="$DESTDIR" install-gcc

# Instala a runtime mínima (libgcc) do target
make -C "$BUILD_DIR" DESTDIR="$DESTDIR" install-target-libgcc

# Links de conveniência (alguns fluxos esperam ${LFS_TGT}-gcc como 'gcc' no $PREFIX/bin durante bootstrap)
# Não tocamos fora do PREFIX.
if [ -x "${DESTDIR}${PREFIX}/bin/${LFS_TGT}-gcc" ] && [ ! -e "${DESTDIR}${PREFIX}/bin/gcc" ]; then
  ln -sf "${LFS_TGT}-gcc" "${DESTDIR}${PREFIX}/bin/gcc"
fi

# Metadados auxiliares
{
  echo "NAME=gcc-stage0"
  echo "TARGET=${LFS_TGT}"
  echo "SYSROOT=${SYSROOT}"
  echo "PREFIX=${PREFIX}"
  echo "LANGS=${ADM_GCC_LANGS}"
  echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${DESTDIR}${PREFIX}/.adm-gcc-stage0.meta" 2>/dev/null || true
