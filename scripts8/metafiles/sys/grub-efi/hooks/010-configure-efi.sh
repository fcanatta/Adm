#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C TZ=UTC

# Plataforma UEFI (x86_64-efi)
OPTS=(
  --with-platform=efi
  --target=x86_64
  --disable-werror
  --enable-efi-secure-boot   # prepara módulos compatíveis
  --enable-device-mapper
)

# Freetype para fontes/temas (opcional)
if pkg-config --exists freetype2 2>/dev/null; then
  OPTS+=( --enable-grub-mkfont )
fi

export CONFIGURE_OPTS="${CONFIGURE_OPTS:-} ${OPTS[*]}"
echo "[grub-efi] CONFIGURE_OPTS=${CONFIGURE_OPTS}"
