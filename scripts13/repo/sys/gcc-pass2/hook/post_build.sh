#!/usr/bin/env bash
# post_build: gcc pass 2 (toolchain final)
# - roda um subconjunto de testes (make -k check) com log
# - sanity-check de compilação nativa

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
: "${ADM_LOGS:="${ADM_BUILD_DIR}"}"

cd "${ADM_BUILD_DIR}/build"

MARKER=".tests-and-sanity-done"
LOGFILE="${ADM_LOGS}/test-gcc-pass2.log"

if [[ -f "${MARKER}" ]]; then
    echo "[gcc-pass2/post_build] Testes/sanity já realizados, pulando."
    exit 0
fi

echo "[gcc-pass2/post_build] Iniciando 'make -k check' (pode demorar)..."
if make -k check >"${LOGFILE}" 2>&1; then
    echo "[gcc-pass2/post_build] Testes concluídos (log: ${LOGFILE})."
else
    echo "[gcc-pass2/post_build] AVISO: falhas em testes, veja:"
    echo "  ${LOGFILE}"
fi

cat > dummy.c <<'EOF'
#include <stdio.h>
int main(void) {
    printf("hello-from-gcc-pass2\n");
    return 0;
}
EOF

if gcc -o dummy dummy.c >/dev/null 2>&1; then
    echo "[gcc-pass2/post_build] gcc compilou e linkou dummy.c com sucesso."
else
    echo "[gcc-pass2/post_build] AVISO: gcc falhou ao compilar dummy.c."
fi

rm -f dummy.c dummy 2>/dev/null || true
touch "${MARKER}"
