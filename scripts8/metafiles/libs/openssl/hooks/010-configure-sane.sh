#!/usr/bin/env bash
set -Eeuo pipefail
# Evita que falta de perl/test harness pare o build inicial
: "${OPENSSL_CONFIG_OPTS:=no-tests}"
export OPENSSL_CONFIG_OPTS
echo "[hook openssl] OPENSSL_CONFIG_OPTS=$OPENSSL_CONFIG_OPTS"
