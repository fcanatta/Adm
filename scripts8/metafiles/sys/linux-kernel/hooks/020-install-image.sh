#!/usr/bin/env bash
set -Eeuo pipefail

: "${DESTDIR:=/}"

# Detecta bzImage
for img in \
  "${KBUILD_OUTPUT}/arch/x86/boot/bzImage" \
  "${KBUILD_OUTPUT}/arch/*/boot/*Image*" \
; do
    if [[ -f "$img" ]]; then
        mkdir -p "${DESTDIR}/boot"
        cp -f "$img" "${DESTDIR}/boot/vmlinuz"
        echo "[kernel] Kernel instalado em /boot/vmlinuz"
        exit 0
    fi
done

echo "[kernel] Aviso: nenhuma imagem encontrada"
