#!/usr/bin/env bash
# /usr/src/adm/scripts/lib.sh
# Biblioteca central de utilitários do ADM Build System
# - Cabeçalho visual aprimorado
# - Logging colorido e resumo na tela
# - Locking (flock)
# - Execução segura com logs
# - Parser simples para metafiles INI
# - Manifest em texto simples
set -euo pipefail

# ---- ensure init is loaded (idempotent) ----
if [ -n "${ADM_SCRIPTS_DIR-}" ] && [ -f "${ADM_SCRIPTS_DIR}/init.sh" ]; then
  # shellcheck disable=SC1090
  source "${ADM_SCRIPTS_DIR}/init.sh"
else
  # minimal fallback defaults if init.sh not yet sourced
  ADM_ROOT=${ADM_ROOT:-/usr/src/adm}
  ADM_SCRIPTS_DIR=${ADM_SCRIPTS_DIR:-"${ADM_ROOT}/scripts"}
  ADM_LOGS=${ADM_LOGS:-"${ADM_ROOT}/logs"}
  ADM_STATE=${ADM_STATE:-"${ADM_ROOT}/state"}
  ADM_PROFILE=${ADM_PROFILE:-performance}
  ADM_NUM_JOBS=${ADM_NUM_JOBS:-$(nproc 2>/dev/null || echo 1)}
  ADM_VERBOSE=${ADM_VERBOSE:-1}
  ADM_LOGFILE=${ADM_LOGFILE:-"${ADM_LOGS}/adm-$(date -u +%Y%m%dT%H%M%SZ).log"}
  ADM_PROJECT_NAME=${ADM_PROJECT_NAME:-"ADM Build System"}
  ADM_VERSION=${ADM_VERSION:-"v1.0"}
fi

# ---- colors ----
COL_RESET="\033[0m"
COL_INFO="\033[1;34m"
COL_OK="\033[1;32m"
COL_WARN="\033[1;33m"
COL_ERR="\033[1;31m"
COL_HDR="\033[1;36m"
COL_DIM="\033[0;37m"
COL_DBG="\033[1;35m"

# ---- utils ----
timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

trim() {
  # trim whitespace
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"  # ltrim
  s="${s%"${s##*[![:space:]]}"}"  # rtrim
  printf "%s" "$s"
}

is_root() { [ "$(id -u)" -eq 0 ]; }

# ---- header: improved visual panel ----
_show_header_internal() {
  local cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
  [ "$cols" -gt 100 ] && cols=100
  [ "$cols" -lt 40 ] && cols=40
  local pad=$((cols-2))
  local host load cpu mem time profile jobs title

  host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown")
  load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0.00")
  # CPU usage: measure deltas over short interval
  if [ -r /proc/stat ]; then
    read -r cpu user nice system idle iowait irq softirq steal guest < /proc/stat
    sleep 0.08
    read -r cpu2 user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 guest2 < /proc/stat
    local total1=$((user+nice+system+idle+iowait+irq+softirq+steal))
    local total2=$((user2+nice2+system2+idle2+iowait2+irq2+softirq2+steal2))
    local diff=$((total2 - total1))
    local busy=$((( (user2+nice2+system2) - (user+nice+system) )))
    if [ "$diff" -gt 0 ]; then
      cpu_percent=$(( busy * 100 / diff ))
      cpu="${cpu_percent}%"
    else
      cpu="0%"
    fi
  else
    cpu="N/A"
  fi
  if command -v free >/dev/null 2>&1; then
    mem=$(free -m | awk '/Mem:/ {printf("%d%%", $3*100/$2)}')
  else
    mem="N/A"
  fi
  time=$(timestamp)
  profile="${ADM_PROFILE:-unknown}"
  jobs="${ADM_NUM_JOBS:-1}"
  title="${ADM_PROJECT_NAME:-ADM Build System} ${ADM_VERSION:-v1.0}"

  # build lines
  local border_top border_mid border_bot
  border_top="╔$(printf '═%.0s' $(seq 1 $pad))╗"
  border_mid="╟$(printf '─%.0s' $(seq 1 $pad))╢"
  border_bot="╚$(printf '═%.0s' $(seq 1 $pad))╝"

  printf "%b%s%b\n" "$COL_HDR" "$border_top" "$COL_RESET"
  # centered title line
  local line1=" ${title} (Profile: ${profile}) "
  printf "%b║%b%*s%*s%b║%b\n" "$COL_HDR" "$COL_DIM" $(( (pad+${#line1})/2 )) "$line1" $(( pad - (pad+${#line1})/2 )) "" "$COL_RESET"
  printf "%b%s%b\n" "$COL_HDR" "$border_mid" "$COL_RESET"
  # metrics lines
  printf "%b║%b Host: %-28s Jobs: %-3s Time: %-20s %b║%b\n" "$COL_HDR" "$COL_DIM" "$host" "$jobs" "$time" "$COL_RESET"
  printf "%b║%b Load: %-8s CPU: %-6s Mem: %-6s%*s %b║%b\n" "$COL_HDR" "$COL_DIM" "$load" "$cpu" "$mem" $((pad-54)) "" "$COL_RESET"
  printf "%b%s%b\n\n" "$COL_HDR" "$border_bot" "$COL_RESET"
}

# show header only if verbose >=1
show_header() {
  if [ "${ADM_VERBOSE:-1}" -ge 1 ]; then
    # ensure ADM_PROJECT_NAME and ADM_VERSION defaults
    ADM_PROJECT_NAME="${ADM_PROJECT_NAME:-ADM Build System}"
    ADM_VERSION="${ADM_VERSION:-v1.0}"
    _show_header_internal
    # also write header summary to logfile (no colors)
    {
      printf "==== %s %s ====\n" "${ADM_PROJECT_NAME}" "${ADM_VERSION}"
      printf "Host: %s\n" "$(hostname -f 2>/dev/null || hostname)"
      printf "Profile: %s | Jobs: %s\n" "${ADM_PROFILE}" "${ADM_NUM_JOBS}"
      printf "Time: %s\n" "$(timestamp)"
      printf "----\n"
    } >> "${ADM_LOGFILE}"
  fi
}

# call header once when lib is sourced
show_header

# ---- logging primitives ----
log_write() {
  local level="$1"; shift
  local msg="$*"
  printf "%s [%s] %s\n" "$(timestamp)" "$level" "$msg" >> "${ADM_LOGFILE}"
}

log_print() {
  local level="$1"; shift
  local msg="$*"
  case "$level" in
    INFO) printf "%b[INFO]%b  %s\n" "${COL_INFO}" "${COL_RESET}" "$msg" ;;
    OK)   printf "%b[ OK ]%b  %s\n" "${COL_OK}" "${COL_RESET}" "$msg" ;;
    WARN) printf "%b[WARN]%b  %s\n" "${COL_WARN}" "${COL_RESET}" "$msg" ;;
    ERR)  printf "%b[ERROR]%b %s\n" "${COL_ERR}" "${COL_RESET}" "$msg" ;;
    DBG)  if [ "${ADM_VERBOSE:-1}" -ge 2 ]; then printf "%b[DBG ]%b  %s\n" "${COL_DBG}" "${COL_RESET}" "$msg"; fi ;;
    *)    printf "%s\n" "$msg" ;;
  esac
  log_write "$level" "$msg"
}

info()  { log_print INFO "$*"; }
ok()    { log_print OK "$*"; }
warn()  { log_print WARN "$*"; }
err()   { log_print ERR "$*"; }
debug() { log_print DBG "$*"; }

fatal() { err "$*"; exit 1; }

# ---- locking (flock) ----
_acquire_fd=9
acquire_lock() {
  mkdir -p "${ADM_STATE}"
  exec ${_acquire_fd}> "${ADM_LOCKFILE}"
  if ! flock -n ${_acquire_fd}; then
    fatal "Another adm process holds lock ${ADM_LOCKFILE}"
  fi
  # write pid for diagnostics
  printf "%s\n" "$$" >&${_acquire_fd}
}
release_lock() {
  # close fd to release
  eval "exec ${_acquire_fd}>&-"
}

# ---- require commands ----
require_cmd() {
  local miss=0
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      warn "Missing required command: $c"
      miss=1
    fi
  done
  [ $miss -eq 0 ] || fatal "One or more required commands are missing"
}

# ---- run command in workdir, write full output to logfile; show short status ----
# usage: run_and_log <workdir> <desc> <cmd...>
run_and_log() {
  local workdir="$1"; shift
  local desc="$1"; shift
  local logfile="${ADM_LOGS}/$(date -u +%Y%m%dT%H%M%SZ)-$(echo "$desc" | tr ' /' '__').log"
  info "START: $desc"
  if [ "${ADM_DRY_RUN:-0}" -eq 1 ]; then
    info "DRY-RUN: $desc"
    return 0
  fi
  (cd "$workdir" && "$@" ) >"${logfile}" 2>&1 || {
    warn "FAILED: $desc (see ${logfile})"
    return 1
  }
  ok "DONE: $desc"
  return 0
}

# ---- simple INI parser helpers ----
# meta_get_ini <metafile> <key>
meta_get_ini() {
  local mf="$1"; local key="$2"
  if [ ! -f "$mf" ]; then
    return 1
  fi
  # grep key= but ignore commented lines starting with #
  local val
  val=$(grep -E "^[[:space:]]*${key}=" "$mf" | tail -n1 | sed -E "s/^[[:space:]]*${key}=[[:space:]]*//")
  printf "%s" "$(trim "$val")"
}

# meta_get_list_ini <metafile> <key> -> returns values as newline-separated
meta_get_list_ini() {
  local mf="$1"; local key="$2"
  local raw
  raw=$(meta_get_ini "$mf" "$key" || echo "")
  # support comma-separated or newline-separated
  if [ -z "$raw" ]; then
    return 0
  fi
  # replace commas with newline, trim
  echo "$raw" | tr ',' '\n' | while IFS= read -r l; do trim "$l"; done
}

# ---- manifest writing: text simple ----
# write_manifest_text <meta_dir> <name> <version> <category> <prefix> <build_system> <status> <installed_files_path>
write_manifest_text() {
  local meta_dir="$1"; shift
  local name="$1"; local version="$2"; local category="$3"
  local prefix="$4"; local buildsys="$5"; local status="$6"; local files_list="$7"
  local manifest_file="${meta_dir}/manifest"
  {
    printf "Name: %s\n" "$name"
    printf "Version: %s\n" "$version"
    printf "Category: %s\n" "$category"
    printf "Prefix: %s\n" "$prefix"
    printf "Profile: %s\n" "${ADM_PROFILE}"
    printf "Build System: %s\n" "$buildsys"
    printf "Installed At: %s\n" "$(timestamp)"
    printf "Status: %s\n" "$status"
    printf "Files:\n"
    if [ -f "$files_list" ]; then
      sed 's/^/  /' "$files_list"
    fi
  } > "$manifest_file"
  ok "Manifesto criado: ${manifest_file}"
}

# collect_installed_files <destdir> <outfile>
collect_installed_files() {
  local dest="$1"; local out="$2"
  if [ ! -d "$dest" ]; then
    warn "collect_installed_files: dest not found: $dest"
    return 1
  fi
  # find all files under dest and output paths relative to /
  (cd "$dest" && find . -type f -print | sed 's|^\./|/|' ) > "$out"
  ok "Lista de arquivos coletada: $out"
}

# ---- helper to test if package is already installed (by manifest) ----
is_installed() {
  local meta_dir="$1"
  [ -f "${meta_dir}/manifest" ] && grep -q '^Status: success' "${meta_dir}/manifest"
}

# ---- small debug dump ----
debug_env() {
  debug "ADM_ROOT=${ADM_ROOT}"
  debug "ADM_SCRIPTS_DIR=${ADM_SCRIPTS_DIR}"
  debug "ADM_DISTFILES=${ADM_DISTFILES}"
  debug "ADM_BINCACHE=${ADM_BINCACHE}"
  debug "ADM_BUILD=${ADM_BUILD}"
  debug "ADM_TOOLCHAIN=${ADM_TOOLCHAIN}"
  debug "ADM_LOGS=${ADM_LOGS}"
  debug "ADM_STATE=${ADM_STATE}"
  debug "ADM_METAFILES=${ADM_METAFILES}"
  debug "ADM_UPDATES=${ADM_UPDATES}"
  debug "ADM_PROFILE=${ADM_PROFILE}"
  debug "ADM_NUM_JOBS=${ADM_NUM_JOBS}"
}
