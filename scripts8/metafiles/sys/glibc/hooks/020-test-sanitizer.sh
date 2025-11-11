#!/usr/bin/env bash
# Em bootstrap inicial, geralmente não executamos a suíte completa de testes
set -Eeuo pipefail
: "${GLIBC_RUN_TESTS:=0}"; export GLIBC_RUN_TESTS
echo "[hook glibc] GLIBC_RUN_TESTS=$GLIBC_RUN_TESTS"
