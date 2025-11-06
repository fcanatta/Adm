#!/usr/bin/env bash
# Script: adm-update-firefox.sh
# Objetivo: buscar nova versão estável do Firefox e gerar metafile de atualização

set -euo pipefail

UPDATE_DIR="/usr/src/adm/update/browser/firefox"
META_FILE="${UPDATE_DIR}/metafile"
TMPFILE="$(mktemp)"

# 1. Verificar última versão disponível via directory listing
echo "Buscando última versão estável do Firefox..."
curl -s https://ftp.mozilla.org/pub/firefox/releases/ | grep -Eo '>[0-9]+\.[0-9]+(\.[0-9]+)?/' | tr -d '/>' | sort -V | tail -n1 > "${TMPFILE}"

if ! NEW_VER=$(cat "${TMPFILE}"); then
  echo "Erro: não foi possível detectar versão." >&2
  rm -f "${TMPFILE}"
  exit 1
fi
rm -f "${TMPFILE}"

echo "Versão detectada: ${NEW_VER}"

# 2. Criar diretório de update se necessário
mkdir -pv "${UPDATE_DIR}"

# 3. Gerar/atualizar metafile
cat > "${META_FILE}" <<EOF
NAME="firefox"
NEW_VERSION="${NEW_VER}"
CATEGORY="browser"
SOURCE_URL="https://ftp.mozilla.org/pub/firefox/releases/${NEW_VER}/source/firefox-${NEW_VER}.source.tar.xz"
CHECKSUM=""  # Opcional: calcular ou inserir manually
EOF

echo "Metafile de atualização criado: ${META_FILE}"
echo "Use adm-update ou adm-build para aplicar esta nova versão."
exit 0
