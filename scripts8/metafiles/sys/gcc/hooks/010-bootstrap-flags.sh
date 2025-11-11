#!/usr/bin/env bash
# Flags mais previsíveis para stage1
set -Eeuo pipefail
export BOOT_CFLAGS="${BOOT_CFLAGS:--O2 -pipe}"
export CFLAGS_FOR_TARGET="${CFLAGS_FOR_TARGET:--O2 -pipe}"
export CXXFLAGS_FOR_TARGET="${CXXFLAGS_FOR_TARGET:--O2 -pipe}"
echo "[hook] gcc: BOOT_CFLAGS='$BOOT_CFLAGS'"
