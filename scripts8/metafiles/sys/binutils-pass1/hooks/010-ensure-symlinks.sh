#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"
: "${TARGET:=}"

# Alguns ambientes instalam em PREFIX/TARGET/bin; garantir bin/ "curto" no PATH
if [[ -n "${TARGET}" && -d "${DESTDIR}${PREFIX}/${TARGET}/bin" ]]; then
  mkdir -p "${DESTDIR}${PREFIX}/bin"
  for t in ar as ld nm objcopy objdump ranlib strip; do
    if [[ -x "${DESTDIR}${PREFIX}/${TARGET}/bin/${TARGET}-${t}" ]]; then
      ln -sf "../${TARGET}/bin/${TARGET}-${t}" "${DESTDIR}${PREFIX}/bin/${TARGET}-${t}"
    fi
  done
  echo "[binutils-pass1] symlinks ${PREFIX}/bin/${TARGET}-* -> ok"
fi
