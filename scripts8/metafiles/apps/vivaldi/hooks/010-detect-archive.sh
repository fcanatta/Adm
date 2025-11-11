#!/usr/bin/env bash
# Detecta o artefato baixado: .deb ou .rpm (não compila nada)
set -Eeuo pipefail

file_found=""
for f in *.deb *.rpm; do
  [[ -f "$f" ]] && file_found="$f" && break
done

if [[ -z "$file_found" ]]; then
  echo "[vivaldi] ERRO: Nenhum .deb/.rpm encontrado nos sources." >&2
  exit 2
fi
echo "[vivaldi] detectado: $file_found"
