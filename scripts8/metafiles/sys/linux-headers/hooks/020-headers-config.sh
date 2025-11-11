#!/usr/bin/env bash
# Ajustes brandos para 'make headers'
set -Eeuo pipefail
# Desativa paralelismo exagerado no passo mrproper/headers (às vezes causa corridas em FS lentos)
: "${MAKEFLAGS:=}"; [[ "${MAKEFLAGS:-}" =~ -j ]] || export MAKEFLAGS="-j1"
echo "[hook linux-headers] MAKEFLAGS=$MAKEFLAGS"
