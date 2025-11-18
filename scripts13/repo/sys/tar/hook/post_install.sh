#!/usr/bin/env bash
# post_install: tar
# - strip leve
# - sanity-check: criar/extrair um tar pequeno

set -euo pipefail

: "${ADM_INSTALL_ROOT:="/"}"
ROOT="${ADM_INSTALL_ROOT%/}"

BIN="${ROOT}/usr/bin/tar"

echo "[tar/post_install] Strip leve do tar."

if command -v strip >/dev/null 2>&1 && [[ -x "${BIN}" ]]; then
    strip --strip-unneeded "${BIN}" 2>/dev/null || true
else
    echo "[tar/post_install] Strip indisponível ou tar ausente."
fi

echo "[tar/post_install] Sanity-check básico."

TMP="${ROOT}/tmp/adm-tar-test.$$"
mkdir -p "${TMP}"

echo "testando" > "${TMP}/arquivo"

"${BIN}" -cf "${TMP}/teste.tar" -C "${TMP}" arquivo >/dev/null 2>&1 && echo "[OK] tar create"
"${BIN}" -xf "${TMP}/teste.tar" -C "${TMP}" >/dev/null 2>&1 && echo "[OK] tar extract"

rm -rf "${TMP}" 2>/dev/null || true

echo "[tar/post_install] sanity-check finalizado."
