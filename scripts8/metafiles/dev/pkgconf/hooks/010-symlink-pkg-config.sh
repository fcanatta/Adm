#!/usr/bin/env bash
set -Eeuo pipefail
# Alguns projetos esperam 'pkg-config' no PATH; muitos pacotes instalam 'pkgconf' binário
if command -v pkgconf >/dev/null 2>&1; then
  d="${DESTDIR:-/}/usr/bin"
  mkdir -p "$d"
  ln -sf pkgconf "$d/pkg-config"
  echo "[hook pkgconf] symlink /usr/bin/pkg-config -> pkgconf"
fi
