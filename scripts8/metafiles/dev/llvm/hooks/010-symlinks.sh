#!/usr/bin/env bash
set -Eeuo pipefail

: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"

mkdir -p "${DESTDIR}${PREFIX}/bin"

for x in clang clang++ lld lldb; do
  [ -x "${DESTDIR}${PREFIX}/bin/$x" ] && echo "[LLVM] found $x"
done
