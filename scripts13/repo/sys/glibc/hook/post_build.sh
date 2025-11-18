#!/usr/bin/env bash
# post_build: glibc
# - roda 'make -k check' se ainda não rodou
# - salva log em ADM_LOGS, se disponível
# - falhas de teste não quebram o build (apenas avisam)

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
: "${ADM_LOGS:="${ADM_BUILD_DIR}"}"

cd "${ADM_BUILD_DIR}/build"

MARKER=".tests-done"
LOGFILE="${ADM_LOGS}/test-glibc.log"

if [[ -f "${MARKER}" ]]; then
    echo "[glibc/post_build] Testes já executados, pulando."
    exit 0
fi

echo "[glibc/post_build] Iniciando 'make -k check' para glibc..."
if make -k check >"${LOGFILE}" 2>&1; then
    echo "[glibc/post_build] Testes concluídos com sucesso (log: ${LOGFILE})."
else
    echo "[glibc/post_build] AVISO: Alguns testes falharam. Consulte o log:"
    echo "  ${LOGFILE}"
fi

touch "${MARKER}"
