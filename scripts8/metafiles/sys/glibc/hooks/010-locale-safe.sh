#!/usr/bin/env bash
# Garante ambiente consistente para o configure da glibc
set -Eeuo pipefail
export LC_ALL=C
export TZ=UTC
# Evita que FLAGS do perfil atrapalhem bootstrap inicial
export CFLAGS="${CFLAGS:--O2 -pipe}"
export CXXFLAGS="${CXXFLAGS:--O2 -pipe}"
echo "[hook] glibc: LC_ALL=C, TZ=UTC, CFLAGS='$CFLAGS'"
