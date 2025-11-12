#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C TZ=UTC

# GRUB com autotools; plataforma BIOS (pc)
OPTS=(
  --with-platform=pc
  --target=i386
  --disable-werror
  --enable-device-mapper
)

# Freetype para temas (opcional)
if pkg-config --exists freetype2 2>/dev/null; then
  OPTS+=( --enable-grub-mkfont )
fi

export CONFIGURE_OPTS="${CONFIGURE_OPTS:-} ${OPTS[*]}"
echo "[grub-pc] CONFIGURE_OPTS=${CONFIGURE_OPTS}"
