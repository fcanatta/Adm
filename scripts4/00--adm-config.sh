#!/usr/bin/env bash
# 00-adm-config.sh
# Configuração base do ADM (source-based package manager)
# - Define caminhos, perfis e build types suportados
# - Carrega overrides de ambiente e de arquivo
# - Normaliza booleanos, valida perfil e opções
# - Opcionalmente cria diretórios-base de trabalho
#
# Pode ser "sourced" por outros scripts:
#   source /usr/src/adm/scripts/00-adm-config.sh
#
# Ou executado diretamente para imprimir um resumo:
#   bash 00-adm-config.sh

###############################################################################
# ⚙️  Guarda de recarga (idempotência)
###############################################################################
if [[ -n "${ADM_CONF_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_CONF_LOADED=1

###############################################################################
# 🧪 Requisitos mínimos do shell (Bash 4+ recomendado)
###############################################################################
_admcfg__require_bash4() {
  # Alguns recursos (arrays associativos, etc.) exigem Bash >= 4
  local major="${BASH_VERSINFO:-0}"
  if [[ -z "$major" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERRO: Bash >= 4 é requerido. Versão atual: ${BASH_VERSION:-desconhecida}" >&2
    return 2
  fi
  return 0
}
_admcfg__require_bash4 || return 2 2>/dev/null || exit 2

###############################################################################
# 🛠️ Utilitários internos (sem dependência de adm-lib)
###############################################################################
# Impressões simples (sem cores aqui; o styling é responsabilidade do adm-lib)
_admcfg__err() { printf 'ERRO: %s\n' "$*" >&2; }
_admcfg__warn() { printf 'AVISO: %s\n' "$*" >&2; }
_admcfg__note() { printf 'INFO: %s\n' "$*" >&2; }

# Normaliza booleanos (true/false/1/0/yes/no/on/off)
_admcfg__to_bool() {
  local v="${1:-}"
  shopt -s nocasematch
  case "$v" in
    1|true|yes|on|y)   echo "true" ;;
    0|false|no|off|n)  echo "false" ;;
    *)                 echo "$v" ;;
  esac
  shopt -u nocasematch
}

# Verifica se valor está presente em uma "lista" (string com itens separados por espaço)
_admcfg__in_list() {
  local needle="$1"; shift || true
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

# Gera caminho absoluto simplificado (não resolve symlinks complexos sem realpath)
_admcfg__abspath() {
  local p="${1:-}"
  [[ -z "$p" ]] && { echo ""; return 0; }
  case "$p" in
    /*) echo "$p" ;;
    *)  echo "$(pwd -P)/$p" ;;
  esac
}

# Cria diretório com verificação de erro (silencioso só quando já existe)
_admcfg__mkdir_p() {
  local d="$1"
  [[ -z "$d" ]] && { _admcfg__err "diretório vazio em _admcfg__mkdir_p"; return 3; }
  if [[ -d "$d" ]]; then return 0; fi
  mkdir -p -- "$d" 2>/dev/null || {
    # Tenta novamente mostrando erro real
    mkdir -p -- "$d" || {
      _admcfg__err "falha ao criar diretório: $d"
      return 3
    }
  }
  return 0
}

# Detecta número de jobs (quando ADM_JOBS=auto)
_admcfg__detect_jobs() {
  local n="1"
  if command -v nproc >/dev/null 2>&1; then
    n="$(nproc 2>/dev/null || echo 1)"
  elif command -v getconf >/dev/null 2>&1; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  fi
  [[ "$n" =~ ^[0-9]+$ ]] || n=1
  echo "$n"
}

# Valida valor "auto|on|off" (para cor)
_admcfg__validate_color_mode() {
  local v="$1"
  case "$v" in
    auto|on|off) return 0 ;;
    *) _admcfg__warn "ADM_COLOR inválido: '$v' → usando 'auto'"; return 1 ;;
  esac
}

# Determina se TTY suporta cor (somente informação; decisão final fica no adm-lib)
_admcfg__tty_has_color() {
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    local colors; colors="$(tput colors 2>/dev/null || echo 0)"
    [[ "$colors" -ge 8 ]] && return 0
  fi
  return 1
}

###############################################################################
# 📦 Defaults (podem ser sobrescritos por ambiente e depois por arquivo)
###############################################################################
# Diretórios-base
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_SCRIPTS:=${ADM_ROOT}/scripts}"
: "${ADM_META_ROOT:=${ADM_ROOT}/metafile}"
: "${ADM_UPDATE_ROOT:=${ADM_ROOT}/update}"
: "${ADM_CACHE_ROOT:=${ADM_ROOT}/cache}"
: "${ADM_CACHE_SOURCES:=${ADM_CACHE_ROOT}/sources}"
: "${ADM_CACHE_TARBALLS:=${ADM_CACHE_ROOT}/tarballs}"
: "${ADM_LOG_ROOT:=${ADM_ROOT}/logs}"
: "${ADM_REGISTRY_ROOT:=${ADM_ROOT}/registry}"
: "${ADM_STAGES_ROOT:=${ADM_ROOT}/stages}"
: "${ADM_TMP_ROOT:=${TMPDIR:-/tmp}/adm}"
: "${ADM_SYS_PREFIX:=/}"

# Build types suportados (constante de validação global)
: "${ADM_BUILD_TYPES:=autotools cmake make meson cargo go python node custom}"

# Perfis suportados e default
: "${ADM_PROFILES:=minimal normal agressive}"
: "${ADM_PROFILE_DEFAULT:=normal}"

# Parâmetros simples
: "${ADM_COLOR:=auto}"          # auto|on|off (validação abaixo)
: "${ADM_OFFLINE:=false}"       # true|false
: "${ADM_CACHE_ENABLE:=true}"   # true|false
: "${ADM_JOBS:=auto}"           # auto|<int>
: "${ADM_AUTOCREATE_DIRS:=true}"# true|false (criar diretórios automaticamente)
: "${ADM_REQUIRE_ROOT:=true}"   # true|false (para instalações reais em /; apenas uma política declarativa)

# Arquivo de override (padrão: /etc/adm.conf, pode ser apontado via ADM_CONF_FILE)
: "${ADM_CONF_FILE:=/etc/adm.conf}"

###############################################################################
# 🔁 2ª camada: variáveis de ambiente já aplicadas (acima com ":=" respeitam)
#     3ª camada: override por arquivo (se existir) → tem MAIOR prioridade
###############################################################################
_admcfg__load_override_file() {
  local f="$1"
  [[ -z "$f" ]] && return 0
  if [[ -f "$f" ]]; then
    # shellcheck source=/dev/null
    . "$f" || {
      _admcfg__err "falha ao carregar arquivo de configuração: $f"
      return 4
    }
  fi
  return 0
}
_admcfg__load_override_file "$ADM_CONF_FILE" || return 4 2>/dev/null || exit 4

###############################################################################
# 🧹 Normalizações e validações finais de configuração
###############################################################################
# Normaliza booleanos
ADM_OFFLINE="$(_admcfg__to_bool "$ADM_OFFLINE")"
ADM_CACHE_ENABLE="$(_admcfg__to_bool "$ADM_CACHE_ENABLE")"
ADM_AUTOCREATE_DIRS="$(_admcfg__to_bool "$ADM_AUTOCREATE_DIRS")"
ADM_REQUIRE_ROOT="$(_admcfg__to_bool "$ADM_REQUIRE_ROOT")"

# Cor: valida e padroniza
if ! _admcfg__validate_color_mode "$ADM_COLOR"; then
  ADM_COLOR="auto"
fi
# Dica informativa para consumidores (adm-lib): 1=habilitar, 0=desabilitar, -1=auto
case "$ADM_COLOR" in
  on)  ADM_COLOR_MODE=1 ;;
  off) ADM_COLOR_MODE=0 ;;
  auto)
    if _admcfg__tty_has_color; then ADM_COLOR_MODE=1; else ADM_COLOR_MODE=0; fi
    ;;
esac
export ADM_COLOR_MODE

# Perfis: valida default
if ! _admcfg__in_list "$ADM_PROFILE_DEFAULT" $ADM_PROFILES; then
  _admcfg__warn "ADM_PROFILE_DEFAULT inválido: '$ADM_PROFILE_DEFAULT' → usando 'normal'"
  ADM_PROFILE_DEFAULT="normal"
fi

# Build types: garantir que a lista não esteja vazia
if [[ -z "${ADM_BUILD_TYPES// }" ]]; then
  _admcfg__err "ADM_BUILD_TYPES vazio — ajuste sua configuração."
  return 5 2>/dev/null || exit 5
fi

# ADM_JOBS: resolver "auto"
if [[ "${ADM_JOBS}" == "auto" ]]; then
  ADM_JOBS="$(_admcfg__detect_jobs)"
else
  if ! [[ "$ADM_JOBS" =~ ^[0-9]+$ ]] || [[ "$ADM_JOBS" -lt 1 ]]; then
    _admcfg__warn "ADM_JOBS inválido: '$ADM_JOBS' → usando auto"
    ADM_JOBS="$(_admcfg__detect_jobs)"
  fi
fi

# Normaliza caminhos para absolutos (evita ambiguidades)
ADM_ROOT="$(_admcfg__abspath "$ADM_ROOT")"
ADM_SCRIPTS="$(_admcfg__abspath "$ADM_SCRIPTS")"
ADM_META_ROOT="$(_admcfg__abspath "$ADM_META_ROOT")"
ADM_UPDATE_ROOT="$(_admcfg__abspath "$ADM_UPDATE_ROOT")"
ADM_CACHE_ROOT="$(_admcfg__abspath "$ADM_CACHE_ROOT")"
ADM_CACHE_SOURCES="$(_admcfg__abspath "$ADM_CACHE_SOURCES")"
ADM_CACHE_TARBALLS="$(_admcfg__abspath "$ADM_CACHE_TARBALLS")"
ADM_LOG_ROOT="$(_admcfg__abspath "$ADM_LOG_ROOT")"
ADM_REGISTRY_ROOT="$(_admcfg__abspath "$ADM_REGISTRY_ROOT")"
ADM_STAGES_ROOT="$(_admcfg__abspath "$ADM_STAGES_ROOT")"
ADM_TMP_ROOT="$(_admcfg__abspath "$ADM_TMP_ROOT")"

# Sanity básica de PATH
if [[ -z "${PATH:-}" ]]; then
  _admcfg__warn "PATH vazio; definindo PATH=/usr/sbin:/usr/bin:/sbin:/bin"
  PATH="/usr/sbin:/usr/bin:/sbin:/bin"
  export PATH
fi

###############################################################################
# 📁 Criação opcional de diretórios-base (controle por ADM_AUTOCREATE_DIRS)
###############################################################################
_admcfg__maybe_create_dirs() {
  [[ "$ADM_AUTOCREATE_DIRS" != "true" ]] && return 0
  local d
  for d in \
    "$ADM_ROOT" "$ADM_SCRIPTS" "$ADM_META_ROOT" "$ADM_UPDATE_ROOT" \
    "$ADM_CACHE_ROOT" "$ADM_CACHE_SOURCES" "$ADM_CACHE_TARBALLS" \
    "$ADM_LOG_ROOT" "$ADM_REGISTRY_ROOT" "$ADM_STAGES_ROOT" "$ADM_TMP_ROOT"
  do
    _admcfg__mkdir_p "$d" || return 6
  done
  return 0
}
_admcfg__maybe_create_dirs || { _admcfg__err "falha ao preparar diretórios base"; return 6 2>/dev/null || exit 6; }

###############################################################################
# 🌐 Políticas (declarativas) exportadas
###############################################################################
# Nota: Estes valores são lidos por outros scripts (adm-lib, adm-download, etc.)
export ADM_ROOT ADM_SCRIPTS ADM_META_ROOT ADM_UPDATE_ROOT
export ADM_CACHE_ROOT ADM_CACHE_SOURCES ADM_CACHE_TARBALLS
export ADM_LOG_ROOT ADM_REGISTRY_ROOT ADM_STAGES_ROOT ADM_TMP_ROOT
export ADM_SYS_PREFIX

export ADM_BUILD_TYPES ADM_PROFILES ADM_PROFILE_DEFAULT
export ADM_COLOR ADM_OFFLINE ADM_CACHE_ENABLE ADM_JOBS ADM_REQUIRE_ROOT

# Indica que a configuração foi carregada com sucesso
export ADM_CONF_LOADED=1

###############################################################################
# 📋 Execução direta: imprime resumo e sai
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "ADM configuração carregada:"
  printf '  ROOT............: %s\n' "$ADM_ROOT"
  printf '  SCRIPTS.........: %s\n' "$ADM_SCRIPTS"
  printf '  META............: %s\n' "$ADM_META_ROOT"
  printf '  UPDATE..........: %s\n' "$ADM_UPDATE_ROOT"
  printf '  CACHE (src).....: %s\n' "$ADM_CACHE_SOURCES"
  printf '  CACHE (tar).....: %s\n' "$ADM_CACHE_TARBALLS"
  printf '  LOGS............: %s\n' "$ADM_LOG_ROOT"
  printf '  REGISTRY........: %s\n' "$ADM_REGISTRY_ROOT"
  printf '  STAGES..........: %s\n' "$ADM_STAGES_ROOT"
  printf '  TMP.............: %s\n' "$ADM_TMP_ROOT"
  printf '  SYS_PREFIX......: %s\n' "$ADM_SYS_PREFIX"
  printf '  BUILD_TYPES.....: %s\n' "$ADM_BUILD_TYPES"
  printf '  PROFILES........: %s (default=%s)\n' "$ADM_PROFILES" "$ADM_PROFILE_DEFAULT"
  printf '  COLOR...........: %s (mode=%s)\n' "$ADM_COLOR" "${ADM_COLOR_MODE:-auto}"
  printf '  OFFLINE.........: %s\n' "$ADM_OFFLINE"
  printf '  CACHE_ENABLE....: %s\n' "$ADM_CACHE_ENABLE"
  printf '  JOBS............: %s\n' "$ADM_JOBS"
  printf '  AUTOCREATE_DIRS.: %s\n' "$ADM_AUTOCREATE_DIRS"
  printf '  CONF_FILE.......: %s (%s)\n' "$ADM_CONF_FILE" "$( [[ -f "$ADM_CONF_FILE" ]] && echo 'usado' || echo 'não encontrado' )"
fi
