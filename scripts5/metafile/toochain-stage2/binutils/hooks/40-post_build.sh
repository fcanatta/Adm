#!/usr/bin/env sh
# Testes opcionais e coleta de versões

set -eu

: "${BUILD_DIR:?BUILD_DIR não definido}"

if [ "${ADM_RUN_TESTS:-0}" -eq 1 ]; then
  make -C "${BUILD_DIR}" -k check || echo "[WARN] testes falharam (tolerado)"
fi

# Coleta versões para diagnóstico
{
  echo "[binutils-version]"
  command -v "${BUILD_DIR}/binutils/ar" >/dev/null 2>&1 && "${BUILD_DIR}/binutils/ar" --version | head -n1 || true
  command -v "${BUILD_DIR}/ld/ld-new" >/dev/null 2>&1 && "${BUILD_DIR}/ld/ld-new" --version | head -n1 || true
} > "${BUILD_DIR}/.versions.log" 2>/dev/null || true
