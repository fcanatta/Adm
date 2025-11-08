#!/usr/bin/env sh
# Testes opcionais: 'make check' da musl é limitado; deixe desligado por padrão

set -eu
: "${SRC_DIR:?}"
if [ "${ADM_RUN_TESTS:-0}" -eq 1 ]; then
  make -C "$SRC_DIR" -k check || echo "[WARN] testes falharam (tolerado)"
fi
