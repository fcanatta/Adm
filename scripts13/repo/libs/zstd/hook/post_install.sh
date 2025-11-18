#!/usr/bin/env bash
# post_install: zstd
# - strip leve de zstd/unzstd/zstdcat
# - sanity-check compress/decompress

set -euo pipefail

: "${ADM_INSTALL_ROOT:="/"}"
ROOT="${ADM_INSTALL_ROOT%/}"

BIN_DIR="${ROOT}/usr/bin"

ZSTD="${BIN_DIR}/zstd"
UNZSTD="${BIN_DIR}/unzstd"
ZSTDCAT="${BIN_DIR}/zstdcat"

echo "[zstd/post_install] Strip leve."

if command -v strip >/dev/null 2>&1; then
    [[ -x "${ZSTD}"    ]] && strip --strip-unneeded "${ZSTD}"    2>/dev/null || true
    [[ -x "${UNZSTD}"  ]] && strip --strip-unneeded "${UNZSTD}"  2>/dev/null || true
    [[ -x "${ZSTDCAT}" ]] && strip --strip-unneeded "${ZSTDCAT}" 2>/dev/null || true
else
    echo "[zstd/post_install] strip não disponível, pulando."
fi

echo "[zstd/post_install] Sanity-check compress/decompress."

TMP="${ROOT}/tmp/adm-zstd-test.$$"
mkdir -p "${TMP}"

echo "testando zstd" > "${TMP}/a"

if "${ZSTD}" -q "${TMP}/a" >/dev/null 2>&1; then
    echo "[OK] zstd compress"
else
    echo "[WARN] zstd falhou no compress"
fi

if "${UNZSTD}" -q "${TMP}/a.zst" >/dev/null 2>&1; then
    echo "[OK] unzstd decompress"
else
    echo "[WARN] unzstd falhou no decompress"
fi

rm -rf "${TMP}" 2>/dev/null || true

echo "[zstd/post_install] sanity-check finalizado."
