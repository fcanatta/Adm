#!/usr/bin/env bash
#
# logger.sh — sistema de logging para ADM
# Local sugerido: /usr/src/adm/scripts/logger.sh
# Uso:
#   source /usr/src/adm/scripts/logger.sh
#   logger_init "/usr/src/adm/var/log/adm.log" "/usr/src/adm/var/log/adm.json.log"
#   log_info "mensagem"
#   log_error "mensagem"
#   spinner_start "Mensagem em progresso..."    # returns spinner id in SPINNER_PID
#   spinner_stop
#
# Projeto: robusto, evita erros silenciosos, usa flock quando disponível,
# escreve JSON+humano, rotação por tamanho, spinner com fallback.
#

# Guard: permitir source sem efeitos colaterais
if [ -n "${_ADM_LOGGER_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
_ADM_LOGGER_LOADED=1

# ---- defaults (podem ser sobrescritos antes de chamar logger_init) ----
: "${ADM_LOG:=/usr/src/adm/var/log/adm.log}"
: "${ADM_JSON_LOG:=/usr/src/adm/var/log/adm.json.log}"
: "${ADM_LOG_MAX_BYTES:=5242880}"   # 5 MB
: "${ADM_LOG_BACKUPS:=5}"
: "${ADM_LOG_LEVEL:=INFO}"          # ERROR, WARN, INFO, DEBUG
: "${ADM_UID:=}"                    # opcional: uid para chown
: "${ADM_GID:=}"                    # opcional: gid para chown

# ---- internal state ----
_LOGGER_READY=0
_SPINNER_PID=""
_SPINNER_MSG=""
_USE_FLOCK=0

# ---- color helpers (safe) ----
_col_support() {
  # returns 0 if stdout is a terminal and tput exists
  if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

if _col_support; then
  CLR_RESET="$(tput sgr0 2>/dev/null || printf '\033[0m')"
  CLR_BOLD="$(tput bold 2>/dev/null || printf '\033[1m')"
  CLR_MAGENTA="$(tput setaf 5 2>/dev/null || printf '\033[1;35m')"
  CLR_YELLOW="$(tput setaf 3 2>/dev/null || printf '\033[0;33m')"
  CLR_RED="$(tput setaf 1 2>/dev/null || printf '\033[0;31m')"
  CLR_GREEN="$(tput setaf 2 2>/dev/null || printf '\033[0;32m')"
  CLR_CYAN="$(tput setaf 6 2>/dev/null || printf '\033[0;36m')"
else
  CLR_RESET=''
  CLR_BOLD=''
  CLR_MAGENTA=''
  CLR_YELLOW=''
  CLR_RED=''
  CLR_GREEN=''
  CLR_CYAN=''
fi

# ---- helpers ----
_logger_safe_mkdir() {
  local dir="$1"
  if [ -z "$dir" ]; then return 1; fi
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null || {
      printf "%s\n" "logger: failed to create dir $dir" >&2
      return 1
    }
  fi
  return 0
}

_logger_atomic_append() {
  # atomic append: write to temp file then cat >> target (with lock if available)
  local target="$1"; shift
  # gather message(s)
  local content
  content="$*"
  if [ -z "$content" ]; then return 0; fi

  # ensure dir exists
  _logger_safe_mkdir "$(dirname "$target")" || return 1

  if command -v flock >/dev/null 2>&1; then
    # use flock on a descriptor
    (
      flock -x 200
      printf '%s\n' "$content" >>"$target"
    ) 200>"$target".lock
    return $?
  else
    # fallback: use temp file and cat (not strictly atomic across processes)
    local tmp
    tmp="$(mktemp "${target}.tmp.XXXXXX")" || return 1
    printf '%s\n' "$content" >"$tmp"
    # ensure append in case other process also writes (race possible)
    cat "$tmp" >>"$target" && rm -f "$tmp"
    return $?
  fi
}

# ---- JSON helper (simple, no jq) ----
_logger_json_escape() {
  # very small JSON escaper for strings
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//
/\\n}"
  s="${s//	/\\t}"
  printf '%s' "$s"
}

# ---- log level numeric mapping ----
_log_level_num() {
  case "${1:-}" in
    ERROR) echo 40;;
    WARN|WARNING) echo 30;;
    INFO) echo 20;;
    DEBUG) echo 10;;
    *) echo 20;; # default INFO
  esac
}

# ---- rotation ----
_logger_rotate_if_needed() {
  local file="$1"
  local maxbytes="$2"
  local backups="$3"
  if [ ! -f "$file" ]; then return 0; fi
  local bytes
  bytes=$(wc -c <"$file" 2>/dev/null || echo 0)
  if [ "$bytes" -lt "$maxbytes" ]; then return 0; fi

  # rotate: file -> file.1, ..., keep backups count
  for ((i=backups-1;i>=1;i--)); do
    if [ -f "${file}.$i" ]; then
      mv -f "${file}.$i" "${file}.$((i+1))" 2>/dev/null || true
    fi
  done
  if [ -f "$file" ]; then
    mv -f "$file" "${file}.1" 2>/dev/null || true
  fi
  # optional: compress oldest? skip for simplicity
  return 0
}

# ---- public API: init ----
logger_init() {
  # usage: logger_init [human_log_path] [json_log_path] [level]
  local human_log_path="${1:-$ADM_LOG}"
  local json_log_path="${2:-$ADM_JSON_LOG}"
  local level="${3:-$ADM_LOG_LEVEL}"

  ADM_LOG="$human_log_path"
  ADM_JSON_LOG="$json_log_path"
  ADM_LOG_LEVEL="$level"

  # ensure dirs exist
  _logger_safe_mkdir "$(dirname "$ADM_LOG")" || return 1
  _logger_safe_mkdir "$(dirname "$ADM_JSON_LOG")" || return 1

  # ensure files exist
  : >"$ADM_LOG" 2>/dev/null || {
    printf "logger_init: cannot initialize log %s\n" "$ADM_LOG" >&2
    return 1
  }
  : >"$ADM_JSON_LOG" 2>/dev/null || {
    printf "logger_init: cannot initialize json log %s\n" "$ADM_JSON_LOG" >&2
    return 1
  }

  # rotation on init (safe)
  _logger_rotate_if_needed "$ADM_LOG" "$ADM_LOG_MAX_BYTES" "$ADM_LOG_BACKUPS" || true
  _logger_rotate_if_needed "$ADM_JSON_LOG" "$ADM_LOG_MAX_BYTES" "$ADM_LOG_BACKUPS" || true

  # decide flock availability
  if command -v flock >/dev/null 2>&1; then
    _USE_FLOCK=1
  else
    _USE_FLOCK=0
  fi

  # traps to stop spinner on exit
  trap '_logger_spinner_force_stop >/dev/null 2>&1 || true' EXIT INT TERM

  _LOGGER_READY=1
  log_info "logger initialized (level=${ADM_LOG_LEVEL})"
  return 0
}

# ---- spinner implementation ----
_spinner_worker() {
  # args: message
  local msg="$1"
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  local i=0
  # detect if tty
  if [ -t 1 ]; then
    while :; do
      printf "\r%s %b%s%b" "${frames[i]}" "${CLR_MAGENTA}${CLR_BOLD}" "$msg" "${CLR_RESET}"
      i=$(((i+1) % ${#frames[@]}))
      sleep 0.08
    done
  else
    # non-interactive: print a single line and wait
    printf "%s %s\n" "[...]" "$msg"
    while :; do sleep 1; done
  fi
}

_logger_spinner_force_stop() {
  # stop spinner without printing OK line (used in traps)
  if [ -n "$_SPINNER_PID" ]; then
    if kill -0 "$_SPINNER_PID" 2>/dev/null; then
      kill "$_SPINNER_PID" 2>/dev/null || true
      wait "$_SPINNER_PID" 2>/dev/null || true
    fi
    _SPINNER_PID=""
    _SPINNER_MSG=""
  fi
  return 0
}

spinner_start() {
  # start spinner in background; returns pid in _SPINNER_PID
  # usage: spinner_start "Mensagem ..." && do_work; spinner_stop "mensagem final"
  local msg="$*"
  if [ -z "$msg" ]; then msg="working..."; fi
  # if spinner already running, update message
  if [ -n "$_SPINNER_PID" ] && kill -0 "$_SPINNER_PID" 2>/dev/null; then
    _SPINNER_MSG="$msg"
    return 0
  fi
  _SPINNER_MSG="$msg"
  # start worker subshell
  ( _spinner_worker "$msg" ) &
  _SPINNER_PID=$!
  # give a moment to spin
  sleep 0.02
  return 0
}

spinner_stop() {
  # stop spinner and print ok line
  local final_msg="${1:-Done}"
  if [ -n "$_SPINNER_PID" ]; then
    if kill -0 "$_SPINNER_PID" 2>/dev/null; then
      kill "$_SPINNER_PID" 2>/dev/null || true
      wait "$_SPINNER_PID" 2>/dev/null || true
    fi
  fi
  _SPINNER_PID=""
  _SPINNER_MSG=""
  # print final OK message
  printf "%b✔️ %b%b%b\n" "${CLR_GREEN}" "${CLR_MAGENTA}${CLR_BOLD}" "${final_msg}" "${CLR_RESET}"
  return 0
}

# ---- human + json log writers ----
_log_write() {
  # internal writer: level human_text json_obj
  local level="$1"; shift
  local text="$*"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # human line
  local human_line="[$ts] [$level] $text"
  # json object
  local jmsg
  jmsg="$(printf '{"ts":"%s","level":"%s","msg":"%s"}' "$ts" "$level" "$(_logger_json_escape "$text")")"

  # write human
  _logger_atomic_append "$ADM_LOG" "$human_line" || {
    # fallback: try direct append
    printf "%s\n" "$human_line" >>"$ADM_LOG" 2>/dev/null || printf "%s\n" "logger: failed to write human log" >&2
  }
  # write json
  _logger_atomic_append "$ADM_JSON_LOG" "$jmsg" || {
    printf "%s\n" "$jmsg" >>"$ADM_JSON_LOG" 2>/dev/null || printf "%s\n" "logger: failed to write json log" >&2
  }
}

# ---- public logging functions ----
log_error() {
  local msg="$*"
  _log_write "ERROR" "$msg"
  # also print to stderr
  printf "%b[%s] %b%s%b\n" "${CLR_RED}${CLR_BOLD}" "ERROR" "${CLR_RESET}" "$msg" >&2
  return 0
}

log_warn() {
  local msg="$*"
  # only log if level <= WARN
  if [ "$( _log_level_num "$ADM_LOG_LEVEL" )" -le "$( _log_level_num WARN )" ]; then
    _log_write "WARN" "$msg"
  fi
  printf "%b[%s] %b%s%b\n" "${CLR_YELLOW}${CLR_BOLD}" "WARN" "${CLR_RESET}" "$msg"
  return 0
}

log_info() {
  local msg="$*"
  if [ "$( _log_level_num "$ADM_LOG_LEVEL" )" -le "$( _log_level_num INFO )" ]; then
    _log_write "INFO" "$msg"
  fi
  printf "%b%s%b\n" "${CLR_CYAN}" "$msg" "${CLR_RESET}"
  return 0
}

log_debug() {
  local msg="$*"
  if [ "$( _log_level_num "$ADM_LOG_LEVEL" )" -le "$( _log_level_num DEBUG )" ]; then
    _log_write "DEBUG" "$msg"
    printf "%b[DEBUG]%b %s\n" "${CLR_MAGENTA}" "${CLR_RESET}" "$msg"
  fi
  return 0
}

# explicit json event writer with optional key-values
log_event_json() {
  # usage: log_event_json "event_name" key1 val1 key2 val2 ...
  local event="$1"; shift
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local payload="{\"ts\":\"$ts\",\"event\":\"$(_logger_json_escape "$event")\""
  while [ $# -gt 0 ]; do
    local k="$1"; local v="$2"; shift 2
    payload="$payload,$(printf '"%s":"%s"' "$k" "$(_logger_json_escape "$v")")"
  done
  payload="$payload}"
  _logger_atomic_append "$ADM_JSON_LOG" "$payload" || printf "%s\n" "$payload" >>"$ADM_JSON_LOG" 2>/dev/null || true
  return 0
}

# ---- utility: tail log safely ----
logger_tail() {
  local file="${1:-$ADM_LOG}"
  local lines="${2:-50}"
  if [ ! -f "$file" ]; then
    printf "%s\n" "(no log file: $file)"
    return 1
  fi
  tail -n "$lines" "$file"
  return 0
}

# ---- ensure rotation periodic call (can be used by cron or called manually) ----
logger_rotate() {
  _logger_rotate_if_needed "$ADM_LOG" "$ADM_LOG_MAX_BYTES" "$ADM_LOG_BACKUPS"
  _logger_rotate_if_needed "$ADM_JSON_LOG" "$ADM_LOG_MAX_BYTES" "$ADM_LOG_BACKUPS"
  return 0
}

# ---- defensive self-check for common failure modes ----
logger_selfcheck() {
  local ok=0
  if [ -z "$ADM_LOG" ] || [ -z "$ADM_JSON_LOG" ]; then
    printf "%s\n" "logger_selfcheck: ADM_LOG or ADM_JSON_LOG not set" >&2
    return 2
  fi
  if ! _logger_safe_mkdir "$(dirname "$ADM_LOG")"; then ok=1; fi
  if ! _logger_safe_mkdir "$(dirname "$ADM_JSON_LOG")"; then ok=1; fi
  # try writing a small test line
  if ! printf '%s\n' "logger_selfcheck: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >>"$ADM_LOG" 2>/dev/null; then
    printf "%s\n" "logger_selfcheck: cannot append to $ADM_LOG" >&2
    ok=1
  fi
  if [ "$ok" -eq 0 ]; then
    printf "%s\n" "logger_selfcheck: OK"
    return 0
  fi
  return 1
}
