#!/usr/bin/env bash
# post_install: musl
# - verifica se o loader dinâmico da musl existe
# - loga aviso se não encontrar

set -euo pipefail

: "${ADM_INSTALL_ROOT:="/"}"

ROOT="${ADM_INSTALL_ROOT%/}"

LOADER="$(find "${ROOT}/lib" -maxdepth 1 -type f -name 'ld-musl-*.so.1' 2>/dev/null | head -n1 || true)"

if [[ -n "${LOADER}" ]]; then
    echo "[musl/post_install] Loader musl encontrado: ${LOADER#${ROOT}}"
else
    echo "[musl/post_install] AVISO: loader musl (ld-musl-*.so.1) não encontrado em ${ROOT}/lib."
fi
