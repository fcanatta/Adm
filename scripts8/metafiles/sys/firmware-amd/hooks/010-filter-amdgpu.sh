#!/usr/bin/env bash
set -Eeuo pipefail

: "${DESTDIR:=/}"
src="."
dst="${DESTDIR}/usr/lib/firmware"

mkdir -p "$dst"

for f in $(find "$src" -type f -path "*/amdgpu/*"); do
    d="$(dirname "$f")"
    mkdir -p "$dst/$d"
    cp -f "$f" "$dst/$d/"
done

echo "[firmware-amd] Instalado"
