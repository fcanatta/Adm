#!/usr/bin/env bash
# log.sh - Central logging facility for ADM Build System
# Location: /usr/src/adm/scripts/log.sh
# Purpose: structured, thread-safe logging with levels, rotation, per-job logs and terminal colorization
# SPDX-License-Identifier: MIT

# Guard: allow multiple sources
: "${ADM_LOG_SH_LOADED:-}" || ADM_LOG_SH_LOADED=0
if [ "$ADM_LOG_SH_LOADED" -eq 1 ]; then
    return 0
fi
ADM_LOG_SH_LOADED=1

# Require bash
if [ -z "$BASH_VERSION" ]; then
    echo "log.sh: WARNING: bash features preferred" >&2
fi

set -u

# Load env if present (but don't fail if not)
ADM_SCRIPTS_DEFAULT="/usr/src/adm/scripts"
: "${ADM_SCRIPTS:=${ADM_SCRIPTS_DEFAULT}}"
if [ -f "${ADM_SCRIPTS}/env.sh" ]; then
    # shellcheck disable=SC1090
    source "${ADM_SCRIPTS}/env.sh" || true
fi

# Defaults (can be overridden by env.sh)
: "${ADM_LOGS:=/usr/src/adm/logs}"
: "${ADM_LOGLEVEL:=INFO}"
: "${ADM_COLOR:=true}"
: "${ADM_LOG_ROTATE_DAYS:=7}"
: "${ADM_LOG_TIMESTAMP_FMT:='%Y-%m-%d %H:%M:%S'}"
: "${ADM_LOG_SESSION:=adm-$(date +%F_%H-%M-%S)}"
: "${ADM_LOG_PID:=${BASHPID:-$$}}"
: "${ADM_JOB_ID:=default}"
: "${ADM_MAX_LOG_LINE:=10000}"
: "${ADM_LOG_ARCHIVE_DIR:=${ADM_LOGS}/archive}"

# Create directories
mkdir -p "$ADM_LOGS" "$ADM_LOG_ARCHIVE_DIR" 2>/dev/null || true

# Utilities: detect flock
_have_flock=false
if command -v flock >/dev/null 2>&1; then _have_flock=true; fi

# Color sequences
_log_color_reset='\e[0m'
_log_color_debug='\e[1;36m'
_log_color_info='\e[1;34m'
_log_color_warn='\e[1;33m'
_log_color_error='\e[1;31m'

# Determine if terminal supports colors
_log_use_color=false
if [ "$ADM_COLOR" = "true" ] && [ -t 1 ]; then
    _log_use_color=true
fi

# Map level to priority
declare -A _LOG_PRI
_LOG_PRI[DEBUG]=10
_LOG_PRI[INFO]=20
_LOG_PRI[WARN]=30
_LOG_PRI[ERROR]=40
_LOG_PRI[FATAL]=50

# Helper: current priority threshold
_log_threshold() {
    local lvl="$1"
    echo "${_LOG_PRI[$lvl]:-20}"
}

_LOG_CURRENT_THRESHOLD=${_LOG_PRI[$ADM_LOGLEVEL]:-${_LOG_PRI[INFO]}}

# Timestamp with optional milliseconds
_log_timestamp() {
    if date +%s >/dev/null 2>&1; then
        # try to include milliseconds if possible
        if date +%Y >/dev/null 2>&1; then
            date +"%Y-%m-%d %H:%M:%S"
        else
            date
        fi
    else
        printf '%s' "$(date)"
    fi
}

# Sanitize message: remove control characters except newline and tab
_log_sanitize() {
    local msg="$1"
    # remove escape sequences and control chars (except newline/tab)
    # keep UTF-8 bytes
    printf '%s' "$msg" | tr -d '\000-\010\013\014\016-\037' || true
}

# File for global session log and per-job
_LOG_GLOBAL_FILE="$ADM_LOGS/${ADM_LOG_SESSION}.log"
_LOG_JOB_FILE="$ADM_LOGS/${ADM_JOB_ID}.log"

# Ensure log files exist and with safe perms
: > "$_LOG_GLOBAL_FILE" 2>/dev/null || true
: > "$_LOG_JOB_FILE" 2>/dev/null || true
chmod 0644 "$_LOG_GLOBAL_FILE" 2>/dev/null || true
chmod 0644 "$_LOG_JOB_FILE" 2>/dev/null || true

# Locking primitives
_log_acquire_lock() {
    local lockfile="$1"
    if $_have_flock; then
        exec 9>"$lockfile" || return 1
        flock -x 9 || return 1
        return 0
    else
        # fallback lockfile with pid
        local tryfile
        tryfile="$lockfile.pid"
        local i=0
        while ! ( set -C; : > "$tryfile" ) 2>/dev/null; do
            # wait briefly
            i=$((i+1))
            sleep 0.05
            if [ $i -gt 200 ]; then
                return 1
            fi
        done
        printf '%s' "${BASHPID:-$$}" > "$tryfile"
        return 0
    fi
}

_log_release_lock() {
    local lockfile="$1"
    if $_have_flock; then
        # close fd9
        exec 9>&- 2>/dev/null || true
        return 0
    else
        local tryfile="$lockfile.pid"
        rm -f "$tryfile" 2>/dev/null || true
        return 0
    fi
}

# Internal atomic write to log file
_log_write_atomic() {
    local file="$1"; shift
    local msg="$*"
    local tmp
    tmp="${file}.$(date +%s%N).tmp"
    umask 022
    printf '%s\n' "$msg" > "$tmp" || return 1
    mv -f "$tmp" "$file" 2>/dev/null || { cat "$tmp" >> "$file" && rm -f "$tmp"; }
    return 0
}

# Core writer: writes to both global and job logs, with locking
_log_write() {
    local level="$1"; shift
    local context="$1"; shift || context=""
    local pkg="$1"; shift || pkg=""
    local message="$*"

    local ts
    ts=$(_log_timestamp)
    local sanitized
    sanitized=$(_log_sanitize "$message")

    local line="[${ts}][${context}][${pkg}][${level}] ${sanitized}"

    # write to terminal based on level and ADM_LOGLEVEL
    local lvlpri=${_LOG_PRI[$level]:-20}
    if [ $lvlpri -ge $_LOG_CURRENT_THRESHOLD ]; then
        if $_log_use_color; then
            local color=''
            case "$level" in
                DEBUG) color="${_log_color_debug}" ;;
                INFO) color="${_log_color_info}" ;;
                WARN) color="${_log_color_warn}" ;;
                ERROR|FATAL) color="${_log_color_error}" ;;
                *) color="" ;;
            esac
            printf '%b%s%b\n' "$color" "$line" "${_log_color_reset}"
        else
            printf '%s\n' "$line"
        fi
    fi

    # try to write to files with lock
    local lockfile="${ADM_LOGS}/.adm_log_lock"
    if _log_acquire_lock "$lockfile"; then
        # write global
        echo "$line" >> "$_LOG_GLOBAL_FILE" 2>/dev/null || true
        # write job-specific
        echo "$line" >> "$_LOG_JOB_FILE" 2>/dev/null || true
        _log_release_lock "$lockfile"
    else
        # fallback: append without lock (best-effort)
        echo "$line" >> "$_LOG_GLOBAL_FILE" 2>/dev/null || true
        echo "$line" >> "$_LOG_JOB_FILE" 2>/dev/null || true
    fi
}

# Public API
log_init() {
    # usage: log_init [jobid] [context]
    local jid="${1:-$ADM_JOB_ID}"
    local ctx="${2:-adm}"
    ADM_JOB_ID="$jid"
    _LOG_JOB_FILE="$ADM_LOGS/${ADM_JOB_ID}.log"
    : > "$_LOG_JOB_FILE" 2>/dev/null || true
    chmod 0644 "$_LOG_JOB_FILE" 2>/dev/null || true
    log_info "$ctx" "$ADM_JOB_ID" "Log initialized for job $ADM_JOB_ID"
}

log_debug() { _log_write DEBUG "$@"; }
log_info() { _log_write INFO "$@"; }
log_warn() { _log_write WARN "$@"; }
log_error() { _log_write ERROR "$@"; }

log_fatal() {
    _log_write FATAL "$@"
    # ensure flush
    sleep 0.01
    # exit depending on context (if sourced, return non-zero)
    if (return 0 2>/dev/null); then
        return 1
    else
        exit 1
    fi
}

log_section() {
    local title="$1"
    local sep='────────────────────────────────────────────────────────────────'
    _log_write INFO "adm" "" "$sep"
    _log_write INFO "adm" "" "  $title"
    _log_write INFO "adm" "" "$sep"
}

# write directly to specific file
log_to_file() {
    local file="$1"; shift
    local msg="$*"
    # sanitize path
    case "$file" in
        /*) : ;; # absolute ok
        *) file="$ADM_LOGS/$file" ;;
    esac
    # atomic
    local lockfile="${file}.lock"
    if _log_acquire_lock "$lockfile"; then
        echo "$(_log_timestamp) $msg" >> "$file" 2>/dev/null || true
        _log_release_lock "$lockfile"
    else
        echo "$(_log_timestamp) $msg" >> "$file" 2>/dev/null || true
    fi
}

# Sanitize and mask secrets (very basic)
log_sanitize() {
    local s="$1"
    # mask things that look like tokens (simple heuristic)
    s=${s//--password[[:space:]]*([![:space:]])/--password=***}
    s=${s//--token[[:space:]]*([![:space:]])/--token=***}
    printf '%s' "$s"
}

# Rotate logs older than ADM_LOG_ROTATE_DAYS (simple daily archive)
log_rotate() {
    local days=${1:-$ADM_LOG_ROTATE_DAYS}
    local cutoff
    cutoff=$(date -d "${days} days ago" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
    mkdir -p "$ADM_LOG_ARCHIVE_DIR" 2>/dev/null || true
    find "$ADM_LOGS" -maxdepth 1 -type f -name "*.log" | while read -r f; do
        # skip current session file
        [ "$f" = "$_LOG_GLOBAL_FILE" ] && continue
        # get file date (YYYY-MM-DD) from name or mtime; move if older
        local mdate
        mdate=$(date -r "$f" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
        if [[ "$mdate" < "$cutoff" ]]; then
            mkdir -p "$ADM_LOG_ARCHIVE_DIR/$mdate" 2>/dev/null || true
            mv -f "$f" "$ADM_LOG_ARCHIVE_DIR/$mdate/" 2>/dev/null || true
        fi
    done
}

# Print a summary for the session
log_summary() {
    # count success/fail heuristically
    local total=0 success=0 fail=0
    for f in "$ADM_LOGS"/*.log; do
        [ -f "$f" ] || continue
        total=$((total+1))
        if grep -q "\[.*\]\[.*\]\[.*\]\[ERROR\]" "$f" 2>/dev/null; then
            fail=$((fail+1))
        else
            success=$((success+1))
        fi
    done
    local elapsed=0
    if [ -n "${ADM_SESSION_START_TS-}" ]; then
        elapsed=$(( $(date +%s) - ADM_SESSION_START_TS ))
    fi
    _log_write INFO adm "" "Session summary: total=${total} success=${success} fail=${fail} time=${elapsed}s"
}

# If disk nearly full, warn and fallback
_log_check_disk() {
    local min_free_mb=${1:-50}
    if df --output=avail -m "$ADM_LOGS" 2>/dev/null | tail -n1 >/dev/null 2>&1; then
        local avail
        avail=$(df --output=avail -m "$ADM_LOGS" 2>/dev/null | tail -n1 || echo 0)
        if [ "$avail" -lt "$min_free_mb" ]; then
            _log_write WARN adm "" "Low disk space for logs: ${avail}MB (< ${min_free_mb}MB)"
            return 1
        fi
    fi
    return 0
}

# Export functions for other scripts
export -f log_init log_debug log_info log_warn log_error log_fatal log_section log_to_file log_rotate log_summary log_sanitize

# Record session start timestamp
ADM_SESSION_START_TS=$(date +%s)
_log_write INFO adm "" "Log subsystem initialized: session=${ADM_LOG_SESSION} pid=${ADM_LOG_PID}"

# Rotate old logs in background (best-effort)
( log_rotate & ) >/dev/null 2>&1 &
