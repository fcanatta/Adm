#!/usr/bin/env bash
# -*- coding: UTF-8 -*-
# /usr/src/adm/scripts/env.sh
# Ambiente inicial do ADM Build System
# Gera/valida diretórios, exporta variáveis e inicializa sessão.
# Requisitos: POSIX-ish Bash. Não executa operações destrutivas.
set -o errexit
set -o nounset
set -o pipefail

# ---------------------------
# Configuráveis (ponto único)
# ---------------------------
ADM_BASE_DEFAULT="/usr/src/adm"
FALLBACK_BASE="/tmp/adm-fallback"

# ---------------------------
# Variáveis internas
# ---------------------------
# BUILD_ID e ADM_BASE poderão ser sobrescritos por perfil/CLI posteriormente
BUILD_ID=""
ADM_BASE="${ADM_BASE:-$ADM_BASE_DEFAULT}"
ADM_SCRIPTS=""
ADM_CONFIG=""
ADM_LOGS=""
ADM_REPO=""
ADM_DB=""
ADM_BUILD=""
ADM_CACHE=""
ADM_BOOTSTRAP=""
ADM_OUTPUT=""
ADM_PROFILE="${ADM_PROFILE:-default}"
ADM_LOGFILE=""
UI_SH_LOADED=no
LOG_SH_LOADED=no

# ---------------------------
# Helper: write to logfile (append)
# ---------------------------
_env_log() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="$*"
  # Ensure logfile exists
  if [[ -n "${ADM_LOGFILE:-}" ]]; then
    printf "%s %s\n" "$ts" "$msg" >>"$ADM_LOGFILE" 2>/dev/null || true
  fi
}

# ---------------------------
# Error handler / trap
# ---------------------------
_env_on_error() {
  local rc=$?
  local lineno=${1:-"unknown"}
  _env_log "[ENV][ERROR] Exit code=${rc} at line ${lineno} (pid $$)."
  # Minimal terminal notice (UI script may override)
  if [[ "$UI_SH_LOADED" = "yes" ]]; then
    # if ui loaded, prefer ui to show error (ui.sh should provide ui_error)
    if declare -F ui_error >/dev/null; then
      ui_error "Falha na inicialização do ambiente. Veja log: ${ADM_LOGFILE}"
    else
      printf "ERROR: Falha na inicialização. Ver log: %s\n" "$ADM_LOGFILE" >&2
    fi
  else
    printf "ERROR: Falha na inicialização. Ver log: %s\n" "$ADM_LOGFILE" >&2
  fi
  # attempt minimal cleanup if needed (non-destructive)
  return $rc
}
trap '_env_on_error ${LINENO}' ERR

# ---------------------------
# env_set_paths
# ---------------------------
env_set_paths() {
  ADM_SCRIPTS="$ADM_BASE/scripts"
  ADM_CONFIG="$ADM_BASE/config"
  ADM_LOGS="$ADM_BASE/logs"
  ADM_REPO="$ADM_BASE/repo"
  ADM_DB="$ADM_BASE/db"
  ADM_BUILD="$ADM_BASE/build"
  ADM_CACHE="$ADM_BASE/cache"
  ADM_BOOTSTRAP="$ADM_BASE/bootstrap"
  ADM_OUTPUT="$ADM_BOOTSTRAP/output"

  export ADM_BASE ADM_SCRIPTS ADM_CONFIG ADM_LOGS ADM_REPO ADM_DB ADM_BUILD ADM_CACHE ADM_BOOTSTRAP ADM_OUTPUT ADM_PROFILE
  _env_log "[ENV] Paths set: ADM_BASE=${ADM_BASE}"
}

# ---------------------------
# env_create_dirs
# Ensure all required directories exist (create if absent).
# If creation fails, try fallback_base and continue.
# ---------------------------
env_create_dirs() {
  local dirs=( "$ADM_BASE" "$ADM_SCRIPTS" "$ADM_CONFIG" "$ADM_LOGS" "$ADM_REPO" "$ADM_DB" "$ADM_BUILD" "$ADM_CACHE" "$ADM_BOOTSTRAP" "$ADM_OUTPUT" "$ADM_BOOTSTRAP/mnt/lfs" )
  local created_any=0
  for d in "${dirs[@]}"; do
    if [[ -d "$d" ]]; then
      _env_log "[ENV] Dir exists: $d"
      continue
    fi
    # attempt create
    if mkdir -p -m 0755 "$d" 2>/dev/null; then
      _env_log "[ENV] Created dir: $d"
      created_any=1
    else
      _env_log "[ENV][WARN] Failed to create dir: $d"
      # attempt fallback
      local fb="${FALLBACK_BASE}${d#$ADM_BASE}"
      if mkdir -p -m 0755 "$fb" 2>/dev/null; then
        _env_log "[ENV] Created fallback dir: $fb"
        created_any=1
        # Remap variable to fallback if top-level ADM_BASE not writable
        # Only remap once to keep consistent
        if [[ "$ADM_BASE" = "${ADM_BASE_DEFAULT}" ]]; then
          ADM_BASE="$FALLBACK_BASE"
          env_set_paths
          _env_log "[ENV] Using fallback ADM_BASE=${ADM_BASE}"
        fi
      else
        _env_log "[ENV][ERROR] Could not create required dir or fallback for: $d"
        return 1
      fi
    fi
  done

  # ensure log dir writable
  if [[ ! -w "$ADM_LOGS" ]]; then
    _env_log "[ENV][WARN] Log dir not writable: $ADM_LOGS"
  fi

  # sync environment exports after potential remap
  export ADM_BASE ADM_SCRIPTS ADM_CONFIG ADM_LOGS ADM_REPO ADM_DB ADM_BUILD ADM_CACHE ADM_BOOTSTRAP ADM_OUTPUT
  return 0
}

# ---------------------------
# env_session_init
# ---------------------------
env_session_init() {
  BUILD_ID="$(date '+%Y-%m-%d_%H-%M-%S')"
  ADM_LOGFILE="${ADM_LOGS}/${BUILD_ID}-env.log"
  # create logfile
  touch "$ADM_LOGFILE" 2>/dev/null || {
    _env_log "[ENV][WARN] Não foi possível criar ADM_LOGFILE: $ADM_LOGFILE. Tentando fallback."
    mkdir -p "$(dirname "$ADM_LOGFILE")" 2>/dev/null || true
    touch "$ADM_LOGFILE" 2>/dev/null || true
  }
  chmod 0644 "$ADM_LOGFILE" 2>/dev/null || true
  export BUILD_ID ADM_LOGFILE
  _env_log "[ENV] Session initialized: BUILD_ID=${BUILD_ID}, LOG=${ADM_LOGFILE}"
}

# ---------------------------
# env_detect_system
# Collect minimal host info and export
# ---------------------------
env_detect_system() {
  # distro / version
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    HOST_DISTRO="${ID:-unknown}"
    HOST_VERSION="${VERSION_ID:-unknown}"
  else
    HOST_DISTRO="unknown"
    HOST_VERSION="unknown"
  fi

  # arch
  HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
  HOST_KERNEL="$(uname -r 2>/dev/null || echo unknown)"

  export HOST_DISTRO HOST_VERSION HOST_ARCH HOST_KERNEL
  _env_log "[ENV] Detected host: ${HOST_DISTRO} ${HOST_VERSION} | ARCH=${HOST_ARCH} | KERNEL=${HOST_KERNEL}"
}

# ---------------------------
# env_set_flags
# Default compile-related flags (safe defaults)
# ---------------------------
env_set_flags() {
  local nproc=1
  if command -v nproc >/dev/null 2>&1; then
    nproc="$(nproc)"
  else
    # fallback: try /proc/cpuinfo
    if [[ -r /proc/cpuinfo ]]; then
      nproc="$(grep -c ^processor /proc/cpuinfo || echo 1)"
    fi
  fi
  MAKEFLAGS="-j${nproc}"
  # Avoid using -march=native to keep bootstrap reproducible across hosts
  CFLAGS="-O2 -pipe"
  CXXFLAGS="-O2 -pipe"
  LDFLAGS="-Wl,-O1,--as-needed"

  # Export
  export MAKEFLAGS CFLAGS CXXFLAGS LDFLAGS
  _env_log "[ENV] Flags set: MAKEFLAGS=${MAKEFLAGS}"
}

# ---------------------------
# env_load_modules
# source ui.sh and log.sh if present (non-fatal)
# ---------------------------
env_load_modules() {
  # ui.sh
  if [[ -r "${ADM_SCRIPTS}/ui.sh" ]]; then
    # shellcheck disable=SC1090
    source "${ADM_SCRIPTS}/ui.sh"
    UI_SH_LOADED="yes"
    _env_log "[ENV] Loaded UI module: ${ADM_SCRIPTS}/ui.sh"
  else
    _env_log "[ENV] UI module not present: ${ADM_SCRIPTS}/ui.sh"
  fi

  # log.sh (if present, load helpers)
  if [[ -r "${ADM_SCRIPTS}/log.sh" ]]; then
    # shellcheck disable=SC1090
    source "${ADM_SCRIPTS}/log.sh"
    LOG_SH_LOADED="yes"
    _env_log "[ENV] Loaded log module: ${ADM_SCRIPTS}/log.sh"
  else
    _env_log "[ENV] Log module not present: ${ADM_SCRIPTS}/log.sh"
  fi
}

# ---------------------------
# Utilities: env_check_var, env_resolve_path, env_reload
# ---------------------------
env_check_var() {
  local varname="$1"
  if [[ -z "${varname:-}" ]]; then
    return 2
  fi
  if [[ -z "${!varname:-}" ]]; then
    _env_log "[ENV][CHECK] Variable '$varname' is not set"
    return 1
  fi
  return 0
}

env_resolve_path() {
  local path="$1"
  if [[ -z "${path:-}" ]]; then
    printf "%s\n" ""
    return 1
  fi
  # expand tilde and resolve relative using builtin
  if [[ "$path" == "~"* ]]; then
    path="${path/#\~/$HOME}"
  fi
  # Use realpath if available
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path"
  else
    # fallback naive normalization
    (cd "$(dirname "$path")" 2>/dev/null && printf "%s/%s\n" "$(pwd -P)" "$(basename "$path")") 2>/dev/null || printf "%s\n" "$path"
  fi
}

env_reload() {
  _env_log "[ENV] Reload requested."
  # Recompute paths and re-export (useful if ADM_BASE changed)
  env_set_paths
  env_create_dirs
  env_session_init
  env_detect_system
  env_set_flags
  _env_log "[ENV] Reload complete."
}

# ---------------------------
# Initialization sequence
# ---------------------------
_main_init() {
  # 1) Ensure ADM_BASE env may be overridden before running this script
  export ADM_BASE

  # 2) set paths (initial)
  env_set_paths

  # 3) create directories (or fallback)
  env_create_dirs

  # 4) init session/logfile
  env_session_init

  # 5) detect system
  env_detect_system

  # 6) set flags for compilation
  env_set_flags

  # 7) try to load optional modules (ui/log)
  env_load_modules

  # 8) final log summary
  _env_log "[ENV] Initialization complete. Profile=${ADM_PROFILE}"
  if [[ "$UI_SH_LOADED" = "yes" ]] && declare -F ui_info >/dev/null; then
    ui_info "Ambiente ADM carregado. Profile=${ADM_PROFILE} | BUILD_ID=${BUILD_ID}"
  else
    printf "[ENV] Ambiente ADM carregado. Profile=%s | BUILD_ID=%s\n" "${ADM_PROFILE}" "${BUILD_ID}"
  fi
}

# Run main init only if script executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _main_init
fi

# Export helper functions for use by other scripts that source env.sh
export -f env_set_paths env_create_dirs env_session_init env_detect_system env_set_flags env_load_modules env_check_var env_resolve_path env_reload
