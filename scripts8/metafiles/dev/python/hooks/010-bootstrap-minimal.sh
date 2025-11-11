#!/usr/bin/env bash
set -Eeuo pipefail
# Evita testes/pip no bootstrap inicial
export CONFIGURE_OPTS="${CONFIGURE_OPTS:-} --without-ensurepip"
# Se ca-certificates ainda não está pronto, alguns downloads HTTPS falham
echo "[hook python] CONFIGURE_OPTS=$CONFIGURE_OPTS"
