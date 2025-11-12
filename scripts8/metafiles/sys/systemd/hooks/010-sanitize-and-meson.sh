#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C TZ=UTC
# systemd ≈ GLIBC; falha cedo se detectar MUSL
if echo | ${CC:-cc} -dM -E - | grep -qi musl; then
  echo "[systemd] ERRO: toolchain MUSL detectado; use elogind+eudev." >&2; exit 2
fi
export CONFIGURE_OPTS="${CONFIGURE_OPTS:-} -Dmode=release -Dman=true -Dlink-udev-shared=true"
echo "[systemd] Meson opts: ${CONFIGURE_OPTS}"
