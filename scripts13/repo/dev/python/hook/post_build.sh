#!/usr/bin/env bash
# post_build: python 3.14.0
# - roda suíte de testes filtrada por profile
# - grava log em ADM_LOGS
# - falhas NÃO abortam o build (só avisam)

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
: "${ADM_LOGS:="${ADM_BUILD_DIR}"}"
: "${ADM_PROFILE:="normal"}"

cd "${ADM_BUILD_DIR}/build"

MARKER=".tests-done"
LOGFILE="${ADM_LOGS}/test-python-3.14.0.log"

if [[ -f "${MARKER}" ]]; then
    echo "[python/post_build] Testes já executados, pulando."
    exit 0
fi

if [[ ! -x "./python" ]]; then
    echo "[python/post_build] Binário ./python não encontrado, não há testes para rodar."
    exit 0
fi

JOBS=1
if command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc || echo 1)"
fi

echo "[python/post_build] Iniciando testes (profile=${ADM_PROFILE}, jobs=${JOBS})"
echo "[python/post_build] Log: ${LOGFILE}"

# Seleção de conjunto de testes por profile
case "${ADM_PROFILE}" in
    minimal)
        # Conjunto bem pequeno, apenas sanity
        TESTS="test_sys test_os test_subprocess test_io"
        ./python -m test -j"${JOBS}" ${TESTS} >"${LOGFILE}" 2>&1 || \
            echo "[python/post_build] AVISO: falhas em testes minimal, veja ${LOGFILE}"
        ;;
    aggressive)
        # Suite bem maior, mas ainda não full
        ./python -m test -j"${JOBS}" \
            -u all \
            --timeout=600 \
            >"${LOGFILE}" 2>&1 || \
            echo "[python/post_build] AVISO: falhas em testes aggressive, veja ${LOGFILE}"
        ;;
    *)
        # normal: subset razoável + core
        TESTS="test_sys test_os test_subprocess test_io test_import test_unittest test_repr"
        ./python -m test -j"${JOBS}" ${TESTS} \
            >"${LOGFILE}" 2>&1 || \
            echo "[python/post_build] AVISO: falhas em testes normal, veja ${LOGFILE}"
        ;;
esac

touch "${MARKER}"
echo "[python/post_build] Testes concluídos (com ou sem falhas). Consulte ${LOGFILE}."
```0
