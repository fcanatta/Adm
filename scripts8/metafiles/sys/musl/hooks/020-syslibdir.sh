#!/usr/bin/env bash
# Alinha syslibdir/prefix com o sysroot usado no bootstrap
set -Eeuo pipefail
: "${SYSROOT:=}"
if [[ -n "${SYSROOT}" ]]; then
  export MUSL_PREFIX="/usr"
  export MUSL_SYSLIBDIR="/usr/lib"
  echo "[hook musl] prefix=$MUSL_PREFIX syslibdir=$MUSL_SYSLIBDIR (sysroot=$SYSROOT)"
else
  echo "[hook musl] sysroot não definido (ok)"
fi
