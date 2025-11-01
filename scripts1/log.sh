#!/usr/bin/env bash
# /usr/src/adm/scripts/log.sh
# Sub-sistema de logging do ADM Build System
# - inicializa logs de sessão
# - funções: log_init, log_event, log_to_file, log_section, log_highlight,
#   log_rotate, log_summary, log_elapsed
#
# Projetado para ser *sourced* por outros scripts:
#   source "/usr/src/adm/scripts/log.sh"#
set -euo pipefail
# shellcheck disable=SC1090
# try to load init if present to obtain ADM_* variables
if [ -n "${ADM_SCRIPTS_DIR-}" ] && [ -f "${ADM_SCRIPTS_DIR}/init.sh" ]; then
  # don't re-source init if already loaded (init.sh idempotent)
  # shellcheck source=/usr/src/adm/scripts/init.sh
  source "${ADM_SCRIPTS_DIR}/init.sh"
fi
# defaults (if init not run)
ADM_ROOT=${ADM_ROOT:-/usr/src/adm}
ADM_LOGS=${ADM_LOGS:-${ADM_ROOT}/logs}
ADM_STATE=${ADM_STATE:-${ADM_ROOT}/state}
ADM_PROFILE=${ADM_PROFILE:-performance}
ADM_NUM_JOBS=${ADM_NUM_JOBS:-1}
ADM_VERBOSE=${ADM_VERBOSE:-1}
ADM_LOGFILE_MAIN=${ADM_LOGFILE:-"${ADM_LOGS}/adm-session-$(date -u +%Y%m%dT%H%M%SZ).log"}
ADM_LOG_ROTATE_KEEP=${ADM_LOG_ROTATE_KEEP:-10}   # keep last N sessions
ADM_LOG_ROTATE_DIR="${ADM_LOGS}/rotated"

# Colors
COL_RESET="\033[0m"
COL_INFO="\033[1;34m"
COL_OK="\033[1;32m"
COL_WARN="\033[1;33m"
COL_ERR="\033[1;31m"
COL_HDR="\033[1;36m"
COL_DIM="\033[0;37m"
COL_BOX="\033[1;35m"

# Session bookkeeping
_LOG_SESSION_STARTED=0
_LOG_START_TS=0
_LOG_PKGS_TOTAL=0
_LOG_PKGS_OK=0
_LOG_PKGS_FAIL=0

# Ensure logs dir exists and permissions (idempotent)
log_init() {
  mkdir -p "${ADM_LOGS}"
  mkdir -p "${ADM_LOG_ROTATE_DIR}"
  chmod 755 "${ADM_LOGS}" 2>/dev/null || true
  touch "${ADM_LOGFILE_MAIN}"
  # record start
  _LOG_SESSION_STARTED=1
  _LOG_START_TS=$(date +%s)
  printf "==== ADM Build System Log ====\n" >> "${ADM_LOGFILE_MAIN}"
  printf "Start: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${ADM_LOGFILE_MAIN}"
  printf "Host: %s\n" "$(hostname -f 2>/dev/null || hostname)" >> "${ADM_LOGFILE_MAIN}"
  printf "Profile: %s | Jobs: %s\n" "${ADM_PROFILE}" "${ADM_NUM_JOBS}" >> "${ADM_LOGFILE_MAIN}"
  printf "----\n" >> "${ADM_LOGFILE_MAIN}"
}

# internal writer to main logfile (no color)
_logfile_write() {
  local level="$1"; shift
  local msg="$*"
  printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$msg" >> "${ADM_LOGFILE_MAIN}"
}

# print to terminal (colored) and write to main logfile
log_event() {
  local level="$1"; shift
  local msg="$*"
  case "$level" in
    INFO) printf "%b[INFO]%b  %s\n" "${COL_INFO}" "${COL_RESET}" "$msg" ;;
    OK)   printf "%b[ OK ]%b  %s\n" "${COL_OK}" "${COL_RESET}" "$msg" ;;
    WARN) printf "%b[WARN]%b  %s\n" "${COL_WARN}" "${COL_RESET}" "$msg" ;;
    ERR)  printf "%b[ERROR]%b %s\n" "${COL_ERR}" "${COL_RESET}" "$msg" ;;
    DBG)  if [ "${ADM_VERBOSE}" -ge 2 ]; then printf "%b[DBG ]%b  %s\n" "${COL_BOX}" "${COL_RESET}" "$msg"; fi ;;
    *)    printf "%s\n" "$msg" ;;
  esac
  _logfile_write "$level" "$msg"
}

# write message to a package-specific logfile (append)
# usage: log_to_file pkgid "message..."
log_to_file() {
  local pkg="$1"; shift
  local msg="$*"
  local pkglog="${ADM_LOGS}/${pkg}-$(date -u +%Y%m%dT%H%M%SZ).log"
  # ensure directory exists
  mkdir -p "${ADM_LOGS}"
  printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "PKG" "$msg" >> "${pkglog}"
}

# show a visual section header in terminal and in main log
log_section() {
  local title="$*"
  local line="────────────────────────────────────────────────────────────────"
  printf "%b%s%b\n" "${COL_BOX}" "${line}" "${COL_RESET}"
  printf "%b  %s%b\n" "${COL_BOX}" "$title" "${COL_RESET}"
  printf "%b%s%b\n" "${COL_BOX}" "${line}" "${COL_RESET}"
  _logfile_write "INFO" "SECTION: ${title}"
}

# highlight a boxed message
log_highlight() {
  local msg="$*"
  printf "%b╭%s╮%b\n" "${COL_HDR}" "$(printf '─%.0s' $(seq 1 60))" "${COL_RESET}"
  printf "%b│ %s%*s │%b\n" "${COL_HDR}" "$msg" $((60 - ${#msg})) ""
  printf "%b╰%s╯%b\n" "${COL_HDR}" "$(printf '─%.0s' $(seq 1 60))" "${COL_RESET}"
  _logfile_write "INFO" "HIGHLIGHT: ${msg}"
}

# rotate logs older than keep threshold
log_rotate() {
  mkdir -p "${ADM_LOG_ROTATE_DIR}"
  # move session logs (adm-session-*.log) older than rotating policy
  # keep the newest ADM_LOG_ROTATE_KEEP files, move older to rotated/
  local files
  IFS=$'\n' read -r -d '' -a files < <(ls -1t "${ADM_LOGS}"/adm-session-*.log 2>/dev/null || printf '') || true
  local idx=0
  for f in "${files[@]}"; do
    idx=$((idx+1))
    if [ "${idx}" -gt "${ADM_LOG_ROTATE_KEEP}" ]; then
      mv -f "$f" "${ADM_LOG_ROTATE_DIR}/" 2>/dev/null || true
    fi
  done
}

# compute elapsed time in human friendly
log_elapsed() {
  if [ "${_LOG_SESSION_STARTED}" -eq 0 ]; then
    echo "00:00:00"
    return
  fi
  local now ts diff h m s
  now=$(date +%s)
  ts=$((_LOG_START_TS))
  diff=$((now - ts))
  h=$((diff/3600))
  m=$(( (diff%3600)/60 ))
  s=$(( diff%60 ))
  printf "%02d:%02d:%02d" "$h" "$m" "$s"
}

# mark package success/failure counters (called by build flow)
log_pkg_result() {
  local pkg="$1"; local res="$2" # res: ok|fail
  _LOG_PKGS_TOTAL=$((_LOG_PKGS_TOTAL+1))
  if [ "$res" = "ok" ]; then
    _LOG_PKGS_OK=$((_LOG_PKGS_OK+1))
    _logfile_write "PKG" "${pkg}: OK"
  else
    _LOG_PKGS_FAIL=$((_LOG_PKGS_FAIL+1))
    _logfile_write "PKG" "${pkg}: FAIL"
  fi
}

# produce session summary: prints to terminal and appends to main log
log_summary() {
  local duration
  duration=$(log_elapsed)
  printf "\n"
  log_section "Build Summary"
  log_event INFO "Duration: ${duration}"
  log_event INFO "Packages processed: ${_LOG_PKGS_TOTAL} (OK: ${_LOG_PKGS_OK}, FAIL: ${_LOG_PKGS_FAIL})"
  log_event INFO "Logs: ${ADM_LOGS}"
  printf "\n" >> "${ADM_LOGFILE_MAIN}"
  printf "End: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${ADM_LOGFILE_MAIN}"
  printf "Duration: %s\n" "${duration}" >> "${ADM_LOGFILE_MAIN}"
  # rotate old logs if needed
  log_rotate
}

# convenience wrapper used by other scripts to print start of package build
log_pkg_start() {
  local pkg="$1"
  log_section "Building: ${pkg}"
  _logfile_write "PKG" "START ${pkg}"
}

# init automatically when sourced (but guard to not re-init repeatedly)
if [ "${_LOG_SESSION_STARTED}" -eq 0 ]; then
  log_init
fi

# export functions for callers (they are shell functions available on source)
export -f log_init log_event log_to_file log_section log_highlight log_rotate log_summary \
  log_elapsed log_pkg_start log_pkg_result
