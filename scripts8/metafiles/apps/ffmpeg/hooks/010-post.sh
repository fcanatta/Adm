#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"

# Confere binários instalados
for b in ffmpeg ffprobe ffplay; do
  if [[ -x "${DESTDIR}${PREFIX}/bin/${b}" ]]; then
    echo "[ffmpeg] ${b} instalado"
  fi
done

# Manpages costumam vir prontas; nada a fazer aqui
