#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"
: "${TARGET:=}"

# Garante drivers curtos do target no PATH "curto" (PREFIX/bin)
if [[ -n "${TARGET}" ]]; then
  mkdir -p "${DESTDIR}${PREFIX}/bin"
  declare -A map=(
    ["${TARGET}-gcc"]="../${TARGET}/bin/gcc"
    ["${TARGET}-g++"]="../${TARGET}/bin/g++"
    ["${TARGET}-cpp"]="../${TARGET}/bin/cpp"
  )
  for link in "${!map[@]}"; do
    local target="${map[$link]}"
    if [[ -x "${DESTDIR}${PREFIX}/${TARGET}/bin/${link##*-}" ]]; then
      ln -sf "${target}" "${DESTDIR}${PREFIX}/bin/${link}"
    elif [[ -x "${DESTDIR}${PREFIX}/${TARGET}/bin/${link#${TARGET}-}" ]]; then
      ln -sf "${target}" "${DESTDIR}${PREFIX}/bin/${link}"
    fi
  done
  echo "[gcc-pass2] symlinks em ${PREFIX}/bin para ${TARGET} OK"
fi
