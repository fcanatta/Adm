#!/usr/bin/env sh
# Opcionalmente roda teste rápido e grava versões no log do pacote

set -eu

: "${BUILD_DIR:?}"
: "${DESTDIR:?}"
: "${PREFIX:?}"

# Tests são caros em stage0; rode apenas se ADM_RUN_TESTS=1
if [ "${ADM_RUN_TESTS:-0}" -eq 1 ]; then
  # -k para não abortar a pipeline inteira se um teste flaky falhar
  make -C "${BUILD_DIR}" -k check || echo "[WARN] testes falharam (tolerado em stage0)"
fi

# Coleta versões para diagnóstico
{
  echo "[binutils-version]"
  "${BUILD_DIR}/binutils"/ar --version 2>/dev/null | head -n1 || true
  "${BUILD_DIR}/binutils"/ld/newld --version 2>/dev/null | head -n1 || true
} > "${BUILD_DIR}/.versions.log" 2>/dev/null || true
