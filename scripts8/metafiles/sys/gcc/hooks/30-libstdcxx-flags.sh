#!/usr/bin/env bash
# Flags para libstdc++ (reduz surpresas no estágio de C++)
set -Eeuo pipefail
export CXXFLAGS_FOR_TARGET="${CXXFLAGS_FOR_TARGET:--O2 -pipe -fno-exceptions -fno-rtti}"
# Caso o projeto exija RTTI/exceptions, o 40-builder deve sobrepor.
echo "[hook gcc/libstdc++] CXXFLAGS_FOR_TARGET=$CXXFLAGS_FOR_TARGET"
