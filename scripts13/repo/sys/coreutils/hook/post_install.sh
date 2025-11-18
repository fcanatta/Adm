#!/usr/bin/env bash
# post_install: coreutils
# - strip leve dos binários
# - sanity-check: ls, cp, mv, chmod

set -euo pipefail

: "${ADM_INSTALL_ROOT:="/"}"
ROOT="${ADM_INSTALL_ROOT%/}"

BIN="${ROOT}/usr/bin"

echo "[coreutils/post_install] Strip leve dos binários coreutils."

if command -v strip >/dev/null 2>&1; then
    for b in ls cp mv chmod chown chgrp mkdir rm rmdir touch head tail chmod cat; do
        if [[ -x "${BIN}/${b}" ]]; then
            strip --strip-unneeded "${BIN}/${b}" 2>/dev/null || true
        fi
    done
else
    echo "[coreutils/post_install] 'strip' não encontrado, ignorando strip."
fi

echo "[coreutils/post_install] Sanity-check básico dos utilitários."

TMP="${ROOT}/tmp/adm-coreutils-test.$$"
mkdir -p "${TMP}"

touch "${TMP}/a" 2>/dev/null && echo "[OK] touch"
ls "${TMP}" >/dev/null 2>&1 && echo "[OK] ls"
cp "${TMP}/a" "${TMP}/b" >/dev/null 2>&1 && echo "[OK] cp"
mv "${TMP}/b" "${TMP}/c" >/dev/null 2>&1 && echo "[OK] mv"
rm -f "${TMP}/a" "${TMP}/c" >/dev/null 2>&1

rmdir "${TMP}" >/dev/null 2>&1 || true

echo "[coreutils/post_install] sanity-check finalizado."
