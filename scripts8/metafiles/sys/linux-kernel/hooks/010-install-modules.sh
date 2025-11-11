#!/usr/bin/env bash
set -Eeuo pipefail

: "${DESTDIR:=/}"
: "${KERNEL_VERSION:=}"

if [[ -z "${KERNEL_VERSION}" ]]; then
    # Tentativa automática
    if [[ -f include/config/kernel.release ]]; then
        KERNEL_VERSION="$(cat include/config/kernel.release)"
    fi
fi

if [[ -z "${KERNEL_VERSION}" ]]; then
    echo "[kernel] Aviso: não consegui detectar versão!"
else
    echo "[kernel] Instalação de módulos para ${KERNEL_VERSION}"
    make O="${KBUILD_OUTPUT}" INSTALL_MOD_PATH="${DESTDIR}" modules_install
fi
