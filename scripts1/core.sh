#!/usr/bin/env bash
# core.sh - núcleo de execução do ADM
# Local sugerido: /usr/src/adm/scripts/core.sh
# Usage (sourcing recommended):
#   source /usr/src/adm/scripts/env.sh    # sets ADM_ROOT etc (optional)
#   source /usr/src/adm/scripts/logger.sh # for log_* and spinner (optional)
#   source /usr/src/adm/scripts/core.sh
#   core_init
#   core_exec_step "Descrição" "command arg1 arg2"
#
# Safety: default respects CORE_DRY_RUN=1 if set (simula). Check code before running.
set -euo pipefail
IFS=$'\n\t'

# ---------------- defaults / env ----------------
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_SCRIPTS:=$ADM_ROOT/scripts}"
: "${ADM_VAR:=$ADM_ROOT/var}"
: "${ADM_LOG:=$ADM_VAR/log/adm.log}"
: "${ADM_CHECKPOINT_DIR:=$ADM_VAR/checkpoints}"
: "${CORE_DRY_RUN:=0}"           # export CORE_DRY_RUN=1 to simulate
: "${CORE_CONTINUE_ON_ERROR:=0}" # if 1, do not abort on step failure (useful for batch ops)

# internal state
_CORE_INITIALIZED=0
_CORE_CURRENT_STEP_ID=""
_CORE_LAST_ERROR=""
_CORE_LAST_STEP_DESC=""
_CORE_STEP_START_TS=0

# try to source env.sh and logger.sh if available; fallback harmless functions
_core_try_source() {
  local f="$1"
  if [ -f "$f" ]; then
    # shellcheck source=/dev/null
    . "$f"
    return 0
  fi
  return 1
}

# minimal fallback loggers if logger.sh not present
_core_fallback_logger() {
  # provide log_info, log_warn, log_error, spinner_start, spinner_stop
  log_info() { printf "[INFO] %s\n" "$*"; }
  log_warn() { printf "[WARN] %s\n" "$*"; }
  log_error() { printf "[ERROR] %s\n" "$*" >&2; }
  spinner_start() { :; } # no-op fallback
  spinner_stop() { :; }  # no-op fallback
  logger_init() { :; }
  logger_tail() { [ -f "${ADM_LOG}" ] && tail -n "${1:-50}" "${ADM_LOG}" || true; }
}

# attempt to load env/logger
_core_try_source "$ADM_SCRIPTS/env.sh" || true
if ! _core_try_source "$ADM_SCRIPTS/logger.sh"; then
  # try system path fallback
  if ! _core_try_source "/usr/src/adm/scripts/logger.sh"; then
    _core_fallback_logger
  fi
fi

# helper for UID/GID safe mkdir
_core_mkdir_p() {
  local dir="$1"
  if [ -z "$dir" ]; then return 1; fi
  mkdir -p "$dir" 2>/dev/null || {
    printf "core: failed to mkdir -p %s\n" "$dir" >&2
    return 1
  }
  return 0
}

# ---------------- utilities ----------------

_core_uuid() {
  # simple unique id: timestamp + random
  printf "%s-%s" "$(date -u +"%Y%m%dT%H%M%SZ")" "${RANDOM}${RANDOM}"
}

_core_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

_core_run_cmd_capture() {
  # run a command with capture to log files; args are command string
  # returns exit code
  local cmdstr="$*"
  # run in a subshell to capture streams
  if [ "${CORE_DRY_RUN:-0}" -eq 1 ]; then
    log_info "(dry-run) would run: $cmdstr"
    return 0
  fi
  # execute
  bash -c "$cmdstr"
  return $?
}

# ---------------- checkpointing ----------------
core_checkpoint() {
  # usage: core_checkpoint <label>
  local label="${1:-checkpoint}"
  _core_mkdir_p "$ADM_CHECKPOINT_DIR" || return 1
  local id
  id=$(_core_uuid)
  local file="$ADM_CHECKPOINT_DIR/${label}-${id}.tar"
  # choose compression if available
  local comp=""
  if command -v zstd >/dev/null 2>&1; then
    comp="zstd"; file="${file}.zst"
  elif command -v xz >/dev/null 2>&1; then
    comp="xz"; file="${file}.xz"
  fi

  # what to checkpoint? scripts, var/db, etc (configurable later)
  local include_dirs=("$ADM_SCRIPTS" "$ADM_VAR/db" "$ADM_ETC" "$ADM_META")
  # build tar command safely; include only existing dirs
  local tarlist=()
  for d in "${include_dirs[@]}"; do
    [ -e "$d" ] && tarlist+=("-C" "$(dirname "$d")" "$(basename "$d")")
  done
  if [ "${#tarlist[@]}" -eq 0 ]; then
    log_warn "core_checkpoint: nothing to checkpoint"
    return 0
  fi

  # create tar (no absolute paths)
  if [ "$comp" = "zstd" ]; then
    tar -cf - "${tarlist[@]}" | zstd -q -o "$file" || {
      log_error "core_checkpoint: failed to write $file"
      return 1
    }
  elif [ "$comp" = "xz" ]; then
    tar -cf - "${tarlist[@]}" | xz -z -c >"$file" || {
      log_error "core_checkpoint: failed to write $file"
      return 1
    }
  else
    tar -cf "$file" "${tarlist[@]}" || {
      log_error "core_checkpoint: failed to write $file"
      return 1
    }
  fi
  log_info "core_checkpoint: created $file"
  printf "%s\n" "$file"
  return 0
}

core_rollback() {
  # usage: core_rollback <checkpoint-file>
  local file="$1"
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    log_error "core_rollback: invalid checkpoint: $file"
    return 2
  fi
  # detect compression via extension
  if [[ "$file" == *.zst ]]; then
    ( zstd -q -d "$file" -c | tar -x -C "/" ) || {
      log_error "core_rollback: failed to extract $file"
      return 1
    }
  elif [[ "$file" == *.xz ]]; then
    ( xz -d -c "$file" | tar -x -C "/" ) || {
      log_error "core_rollback: failed to extract $file"
      return 1
    }
  else
    tar -xf "$file" -C "/" || {
      log_error "core_rollback: failed to extract $file"
      return 1
    }
  fi
  log_warn "core_rollback: restored checkpoint $file"
  return 0
}

# ---------------- execution helpers ----------------
core_require_tool() {
  # usage: core_require_tool <tool> [hint]
  local tool="$1"; local hint="${2:-}"
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Required tool not found: $tool ${hint:+(hint: $hint)}"
    return 2
  fi
  return 0
}

core_validate_env() {
  # ensure ADM_ROOT exists or can be created, ensure log dir exists
  if [ -z "$ADM_ROOT" ]; then
    log_error "ADM_ROOT not set"
    return 2
  fi
  if [ ! -d "$ADM_ROOT" ]; then
    if ! mkdir -p "$ADM_ROOT" 2>/dev/null; then
      log_error "Cannot create ADM_ROOT: $ADM_ROOT (permission?)"
      return 2
    fi
  fi
  _core_mkdir_p "$ADM_VAR" || return 2
  _core_mkdir_p "$ADM_CHECKPOINT_DIR" || return 2
  return 0
}

_core_start_step() {
  _CORE_CURRENT_STEP_ID="$(_core_uuid)"
  _CORE_STEP_START_TS="$(date +%s)"
  return 0
}

_core_end_step() {
  local rc="$1"
  local desc="$2"
  local now
  now=$(date +%s)
  local dur=$((now - _CORE_STEP_START_TS))
  if [ "$rc" -eq 0 ]; then
    spinner_stop "$desc"
    log_info "Step success: $desc (duration ${dur}s)"
  else
    spinner_stop "$desc"
    log_error "Step failed: $desc (duration ${dur}s) rc=$rc"
  fi
  return "$rc"
}

core_exec_step() {
  # usage: core_exec_step "Description" "cmd string"
  # returns command exit code (non-zero on failure)
  local desc="$1"; shift
  local cmdstr="$*"

  _CORE_LAST_STEP_DESC="$desc"
  _core_start_step
  _CORE_LAST_ERROR=""

  # show spinner and description
  if [ "${CORE_DRY_RUN:-0}" -eq 1 ]; then
    spinner_start "(dry-run) $desc"
    log_info "(dry-run) will run: $cmdstr"
    spinner_stop "(dry-run) $desc (simulated)"
    return 0
  fi

  spinner_start "$desc"

  # create a checkpoint before running a potentially destructive step
  local ck
  ck="$(core_checkpoint "${desc// /-}" 2>/dev/null || true)"
  # run the command; capture exit code
  local rc=0
  if ! bash -c "$cmdstr"; then
    rc=$?
  fi

  _core_end_step "$rc" "$desc"

  if [ "$rc" -ne 0 ]; then
    _CORE_LAST_ERROR="Step '$desc' failed with rc=$rc"
    # attempt rollback if checkpoint is available
    if [ -n "$ck" ] && [ -f "$ck" ]; then
      log_warn "Attempting rollback using checkpoint: $ck"
      if ! core_rollback "$ck"; then
        log_error "Rollback failed for checkpoint $ck"
      fi
    else
      log_warn "No checkpoint to rollback for step: $desc"
    fi
    if [ "${CORE_CONTINUE_ON_ERROR:-0}" -eq 1 ]; then
      log_warn "CORE_CONTINUE_ON_ERROR=1 set: continuing despite error"
      return "$rc"
    fi
    return "$rc"
  fi

  return 0
}

core_dryrun() {
  # usage: core_dryrun "Description" "cmd..."
  local desc="$1"; shift
  local cmdstr="$*"
  spinner_start "(dry-run) $desc"
  log_info "(dry-run) $cmdstr"
  # present a structured plan
  printf "PLAN: %s\nCOMMAND: %s\n" "$desc" "$cmdstr"
  spinner_stop "(dry-run) $desc (simulated)"
  return 0
}

# ---------------- module loader ----------------
core_load_module() {
  # usage: core_load_module <module_name> (module is a script in ADM_SCRIPTS)
  local name="$1"
  local path="$ADM_SCRIPTS/$name"
  if [ ! -f "$path" ]; then
    log_warn "core_load_module: missing module $name at $path"
    return 1
  fi
  # source in a subshell? no, we want functions exported to caller; but guard failures
  # attempt safe source
  if ! . "$path"; then
    log_error "core_load_module: failed to source $path"
    return 2
  fi
  log_info "core_load_module: loaded $name"
  return 0
}

# ---------------- traps and cleanup ----------------
core_trap_err() {
  local rc="$?"
  log_error "core_trap_err: error detected (rc=$rc) at ${BASH_SOURCE[1]}:${BASH_LINENO[0]}"
  _CORE_LAST_ERROR="trap_err rc=$rc"
  # do not immediately exit here; core_exec_step handles rollback
  return 0
}

core_trap_int() {
  log_warn "core_trap_int: interrupted by user"
  # stop spinner if running
  spinner_stop "interrupted"
  # attempt safe rollback? leave to caller decision
  return 0
}

core_trap_exit() {
  local rc="$?"
  spinner_stop "exiting"
  if [ "$rc" -ne 0 ]; then
    log_warn "core_trap_exit: exit code $rc"
  fi
  return 0
}

core_set_traps() {
  trap 'core_trap_err' ERR
  trap 'core_trap_int' INT TERM
  trap 'core_trap_exit' EXIT
  return 0
}

# ---------------- status / selftest ----------------
core_status() {
  echo "ADM_ROOT: $ADM_ROOT"
  echo "ADM_SCRIPTS: $ADM_SCRIPTS"
  echo "ADM_VAR: $ADM_VAR"
  echo "ADM_CHECKPOINT_DIR: $ADM_CHECKPOINT_DIR"
  echo "CORE_DRY_RUN: ${CORE_DRY_RUN:-0}"
  echo "CORE_CONTINUE_ON_ERROR: ${CORE_CONTINUE_ON_ERROR:-0}"
  echo "Last step: ${_CORE_LAST_STEP_DESC:-none}"
  [ -n "${_CORE_LAST_ERROR:-}" ] && echo "Last error: ${_CORE_LAST_ERROR}"
  return 0
}

core_selftest() {
  # minimal selftest to validate environment and basic functions
  local ok=0
  core_validate_env || ok=1
  core_require_tool tar || ok=1
  core_require_tool bash || ok=1
  # test executing a harmless command
  if ! core_exec_step "selftest: echo hello" "echo hello >/dev/null"; then
    ok=1
  fi
  if [ "$ok" -eq 0 ]; then
    log_info "core_selftest: OK"
    return 0
  fi
  log_error "core_selftest: FAILED"
  return 1
}

# ---------------- init ----------------
core_init() {
  if [ "$_CORE_INITIALIZED" -eq 1 ]; then
    return 0
  fi
  # ensure base dirs
  _core_mkdir_p "$ADM_VAR"
  _core_mkdir_p "$ADM_CHECKPOINT_DIR"
  _core_mkdir_p "$ADM_SCRIPTS"
  _core_mkdir_p "$ADM_META"
  # if logger provides logger_init, call it (safe)
  if command -v logger_init >/dev/null 2>&1; then
    logger_init "${ADM_LOG}" "${ADM_LOG%.log}.json.log" || true
  fi
  core_set_traps
  _CORE_INITIALIZED=1
  log_info "core_init: initialized at $(_core_now)"
  return 0
}

# ---------------- CLI when run directly ----------------
_core_usage() {
  cat <<EOF
core.sh - core utilities for ADM (sourcing recommended)
Usage:
  source core.sh
  core_init
  core_status
  core_selftest
  core_exec_step "descr" "command..."
  core_checkpoint <label>
  core_rollback <file>
EOF
}

# allow running small commands if executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    init) core_init;;
    status) core_status;;
    selftest) core_init; core_selftest;;
    checkpoint) core_init; core_checkpoint "${2:-auto}";;
    rollback) core_rollback "${2:-}";;
    help|-h|--help) _core_usage;;
    *) _core_usage; exit 1;;
  esac
fi
