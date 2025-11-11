#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"
: "${TARGET:=}"

# Garante que o driver do TARGET esteja no PATH curto
if [[ -n "${TARGET}" && -d "${DESTDIR}${PREFIX}/bin" ]]; then
  if [[ -x "${DESTDIR}${PREFIX}/bin/${TARGET}-gcc" ]]; then
    echo "[gcc-pass1] ${PREFIX}/bin/${TARGET}-gcc detectado."
  elif [[ -x "${DESTDIR}${PREFIX}/${TARGET}/bin/gcc" ]]; then
    ln -sf "../${TARGET}/bin/gcc" "${DESTDIR}${PREFIX}/bin/${TARGET}-gcc"
    echo "[gcc-pass1] symlink ${PREFIX}/bin/${TARGET}-gcc -> ../${TARGET}/bin/gcc"
  fi
fi
