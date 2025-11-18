#!/usr/bin/env bash
# post_install: glibc
# - roda ldconfig se disponível
# - sanity-check simples do loader dinâmico

set -euo pipefail

: "${ADM_INSTALL_ROOT:="/"}"

ROOT="${ADM_INSTALL_ROOT%/}"
if command -v chroot >/dev/null 2>&1 && [[ -x "${ROOT}/sbin/ldconfig" ]]; then
    echo "[glibc/post_install] Rodando ldconfig dentro do root '${ROOT}'."
    chroot "${ROOT}" /sbin/ldconfig || echo "[glibc/post_install] AVISO: ldconfig retornou erro."
fi

# Sanity: procurar loader dinâmico
LOADER="$(find "${ROOT}/lib" "${ROOT}/lib64" -maxdepth 1 -type f -name 'ld-linux*.so.*' 2>/dev/null | head -n1 || true)"
if [[ -n "${LOADER}" ]]; then
    echo "[glibc/post_install] Loader dinâmico detectado: ${LOADER#${ROOT}}"
else
    echo "[glibc/post_install] AVISO: loader dinâmico (ld-linux*.so.*) não encontrado em ${ROOT}/lib*."
fi
