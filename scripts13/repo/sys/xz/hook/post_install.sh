#!/usr/bin/env bash
# post_install: xz
# - strip leve
# - sanity-check: compress/decompress

set -euo pipefail

: "${ADM_INSTALL_ROOT:="/"}"
ROOT="${ADM_INSTALL_ROOT%/}"

XZ="${ROOT}/usr/bin/xz"
UNXZ="${ROOT}/usr/bin/unxz"

echo "[xz/post_install] Strip leve."

if command -v strip >/dev/null 2>&1; then
    [[ -x "${XZ}" ]] && strip --strip-unneeded "${XZ}" 2>/dev/null || true
    [[ -x "${UNXZ}" ]] && strip --strip-unneeded "${UNXZ}" 2>/dev/null || true
else
    echo "[xz/post_install] strip não disponível."
fi

echo "[xz/post_install] Sanity-check xz/unxz."

TMP="${ROOT}/tmp/adm-xz-test.$$"
mkdir -p "${TMP}"

echo "testando xz" > "${TMP}/a"

if "${XZ}" "${TMP}/a" >/dev/null 2>&1; then
    echo "[OK] xz compress"
else
    echo "[WARN] xz falhou no compress"
fi

if "${UNXZ}" "${TMP}/a.xz" >/dev/null 2>&1; then
    echo "[OK] unxz decompress"
else
    echo "[WARN] unxz falhou no decompress"
fi

rm -rf "${TMP}" 2>/dev/null || true

echo "[xz/post_install] sanity-check finalizado."
