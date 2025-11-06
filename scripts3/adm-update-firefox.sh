#!/usr/bin/env bash
# adm-update-firefox.sh
# Atualiza automaticamente o metafile do Firefox com a nova versão estável
# Autor: ADM System (GPT5)
# Compatível com: adm-update, adm-db, notify-send

set -euo pipefail

# Configuração
UPDATE_DIR="/usr/src/adm/update/browser/firefox"
META_FILE="${UPDATE_DIR}/metafile"
TMP_HTML="$(mktemp)"
TMP_SHA="$(mktemp)"
CURRENT_VERSION="unknown"
NEW_VERSION=""
SOURCE_URL=""
CHECKSUM=""

# Função de log colorido
log() { printf "\033[1;36m[adm-update-firefox]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERRO]\033[0m %s\n" "$*" >&2; }

# Função segura para notificação (usa notify-send se disponível)
notify() {
  local title="$1"; shift
  local msg="$*"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "ADM Update" "$title" "$msg"
  else
    log "Notificação: ${title} — ${msg}"
  fi
}

# 1️⃣ Verificar se há versão atual registrada no adm-db
if command -v adm-db >/dev/null 2>&1; then
  CURRENT_VERSION="$(adm-db info firefox 2>/dev/null | awk -F': ' '/Version/{print $2}' || true)"
  CURRENT_VERSION="${CURRENT_VERSION:-unknown}"
else
  if [ -f "${META_FILE}" ]; then
    CURRENT_VERSION="$(grep -E '^INSTALLED_VERSION=' "${META_FILE}" | cut -d= -f2 | tr -d '"')" || true
  fi
fi

log "Versão atual detectada: ${CURRENT_VERSION}"

# 2️⃣ Buscar a última versão estável no site da Mozilla
log "Buscando última versão estável do Firefox..."
if ! curl -fsSL "https://ftp.mozilla.org/pub/firefox/releases/" -o "${TMP_HTML}"; then
  err "Falha ao obter lista de versões do site da Mozilla."
  notify "Falha no update do Firefox" "Não foi possível acessar archive.mozilla.org"
  exit 1
fi

NEW_VERSION="$(grep -Eo '>[0-9]+\.[0-9]+(\.[0-9]+)?/' "${TMP_HTML}" | tr -d '/>' | sort -V | tail -n1 || true)"
rm -f "${TMP_HTML}"

if [ -z "${NEW_VERSION}" ]; then
  err "Não foi possível detectar a nova versão."
  notify "Erro ao buscar versão" "Nenhuma versão encontrada no site da Mozilla."
  exit 1
fi

log "Versão mais recente detectada: ${NEW_VERSION}"

# 3️⃣ Comparar versões
if [ "${CURRENT_VERSION}" = "${NEW_VERSION}" ]; then
  log "Firefox já está atualizado (${CURRENT_VERSION})."
  notify "Firefox atualizado" "Nenhuma nova versão disponível."
  exit 0
fi

# 4️⃣ Montar URL do source tarball
SOURCE_URL="https://archive.mozilla.org/pub/firefox/releases/${NEW_VERSION}/source/firefox-${NEW_VERSION}.source.tar.xz"

# 5️⃣ Verificar se o arquivo existe
log "Verificando disponibilidade do tarball..."
if ! curl -Ifs "${SOURCE_URL}" >/dev/null; then
  err "Arquivo fonte ${SOURCE_URL} não encontrado no servidor."
  notify "Erro no update do Firefox" "Tarball ${NEW_VERSION} não encontrado."
  exit 1
fi

# 6️⃣ Calcular checksum SHA256
log "Baixando tarball temporariamente para calcular SHA256..."
if curl -fsSL "${SOURCE_URL}" -o "${TMP_SHA}"; then
  CHECKSUM="$(sha256sum "${TMP_SHA}" | awk '{print $1}')"
  log "SHA256: ${CHECKSUM}"
else
  err "Falha ao baixar arquivo para cálculo de checksum."
  notify "Erro no update do Firefox" "Falha no download do tarball."
  exit 1
fi
rm -f "${TMP_SHA}"

# 7️⃣ Criar diretório de update
mkdir -pv "${UPDATE_DIR}"

# 8️⃣ Gerar novo metafile de atualização
cat > "${META_FILE}" <<EOF
NAME="firefox"
CATEGORY="browser"
INSTALLED_VERSION="${CURRENT_VERSION}"
NEW_VERSION="${NEW_VERSION}"
SOURCE_URL="${SOURCE_URL}"
CHECKSUM="${CHECKSUM}"
LAST_UPDATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

log "Novo metafile de atualização criado em: ${META_FILE}"
log "Versão ${CURRENT_VERSION} → ${NEW_VERSION}"

# 9️⃣ Notificação visual de sucesso
notify "Atualização do Firefox disponível" "Nova versão detectada: ${NEW_VERSION} (atual: ${CURRENT_VERSION})"

# 🔟 Registrar evento no adm-db (se disponível)
if command -v adm-db >/dev/null 2>&1; then
  adm-db log "firefox" "update-available" "${NEW_VERSION}" || true
fi

log "Script finalizado com sucesso."
exit 0
