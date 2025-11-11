#!/usr/bin/env bash
# Remove variáveis de rpath perigosas vindas do host
set -Eeuo pipefail
unset LD_RUN_PATH || true
unset LIBRARY_PATH || true
echo "[hook binutils] rpath vars desabilitadas"
