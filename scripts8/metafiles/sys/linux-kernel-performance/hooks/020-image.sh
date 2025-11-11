#!/usr/bin/env bash
set -Eeuo pipefail

: "${DESTDIR:=/}"

for img in \
    "${KBUILD_OUTPUT}/arch/x86/boot/bzImage" \
    "${KBUILD_OUTPUT}/arch/*/boot/*Image*" \
; do
    if [[ -f "$img" ]]; then
        mkdir -p "${DESTDIR}/boot"
        cp -f "$img" "${DESTDIR}/boot/vmlinuz-performance"
        echo "[kernel performance] instalado em /boot/vmlinuz-performance"
        exit 0
    fi
done

echo "[kernel performance] aviso: imagem não encontrada"
