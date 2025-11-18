#!/usr/bin/env bash
# post_build: binutils pass 2
# - roda 'make -k check' e registra log

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
: "${ADM_LOGS:="${ADM_BUILD_DIR}"}"

cd "${ADM_BUILD_DIR}/build"

MARKER=".tests-done"
LOGFILE="${ADM_LOGS}/test-binutils-pass2.log"

if [[ -f "${MARKER}" ]]; then
    echo "[binutils-pass2/post_build] Testes já executados, pulando."
    exit 0
fi

echo "[binutils-pass2/post_build] Executando 'make -k check'..."
if make -k check >"${LOGFILE}" 2>&1; then
    echo "[binutils-pass2/post_build] Testes concluídos (log: ${LOGFILE})."
else
    echo "[binutils-pass2/post_build] AVISO: falhas em testes, veja:"
    echo "  ${LOGFILE}"
fi

touch "${MARKER}"
