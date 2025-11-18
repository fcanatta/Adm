#!/usr/bin/env bash
# post_build: musl
# - tenta rodar 'make check' se alvo suportar
# - log em ADM_LOGS
# - falhas não abortam o build

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
: "${ADM_LOGS:="${ADM_BUILD_DIR}"}"

cd "${ADM_BUILD_DIR}/build"

MARKER=".tests-done"
LOGFILE="${ADM_LOGS}/test-musl.log"

if [[ -f "${MARKER}" ]]; then
    echo "[musl/post_build] Testes já executados, pulando."
    exit 0
fi

if grep -q "^check:" Makefile 2>/dev/null; then
    echo "[musl/post_build] Executando 'make check' para musl..."
    if make check >"${LOGFILE}" 2>&1; then
        echo "[musl/post_build] Testes concluídos com sucesso (log: ${LOGFILE})."
    else
        echo "[musl/post_build] AVISO: Alguns testes falharam, veja:"
        echo "  ${LOGFILE}"
    fi
else
    echo "[musl/post_build] Alvo 'check' não encontrado, nenhum teste executado."
fi

touch "${MARKER}"
