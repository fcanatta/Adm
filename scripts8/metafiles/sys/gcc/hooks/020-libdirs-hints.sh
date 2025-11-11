#!/usr/bin/env bash
# Dicas de diretórios para toolchain isolado
set -Eeuo pipefail
: "${SYSROOT:=}"; : "${PREFIX:=}"; : "${TARGET:=}"
if [[ -n "${SYSROOT}" ]]; then
  export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
fi
if [[ -n "${PREFIX}" && -n "${TARGET}" ]]; then
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/$TARGET/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
fi
echo "[hook gcc] sysroot/prefix hints aplicados"
