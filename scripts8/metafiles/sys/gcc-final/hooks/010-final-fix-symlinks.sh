#!/usr/bin/env bash
# Garante symlinks padrão e “driver curto”
set -Eeuo pipefail

: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"
: "${TARGET:=}"

bindir="${DESTDIR}${PREFIX}/bin"
tbindir="${DESTDIR}${PREFIX}/${TARGET}/bin"

mkdir -p "${bindir}"

declare -A links=(
  ["${TARGET}-gcc"]="../${TARGET}/bin/gcc"
  ["${TARGET}-g++"]="../${TARGET}/bin/g++"
  ["${TARGET}-cpp"]="../${TARGET}/bin/cpp"
)

for link in "${!links[@]}"; do
    ln -sf "${links[$link]}" "${bindir}/${link}"
done

echo "[gcc-final] Symlinks OK em ${PREFIX}/bin"
