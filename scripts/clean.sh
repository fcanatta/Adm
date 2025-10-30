#!/usr/bin/env bash
# clean.sh - Safe cleaning utilities for ADM Build System
# Location: /usr/src/adm/scripts/clean.sh
# Purpose: selective cleanup (tmp, cache, logs, builds, orphans), dry-run mode,
#          integration with scheduler, robust error handling and reporting
# SPDX-License-Identifier: MIT

# Guard to allow sourcing
: "${ADM_CLEAN_SH_LOADED:-}" || ADM_CLEAN_SH_LOADED=0
if [ "$ADM_CLEAN_SH_LOADED" -eq 1 ]; then
    return 0
fi
ADM_CLEAN_SH_LOADED=1

set -uo pipefail
IFS=$'\n\t'

# Load environment and helpers if present (non-fatal)
ADM_SCRIPTS_DEFAULT="/usr/src/adm/scripts"
: "${ADM_SCRIPTS:=${ADM_SCRIPTS_DEFAULT}}"
if [ -f "${ADM_SCRIPTS}/env.sh" ]; then
    # shellcheck disable=SC1090
    source "${ADM_SCRIPTS}/env.sh" || true
fi
if [ -f "${ADM_SCRIPTS}/log.sh" ]; then
    # shellcheck disable=SC1090
    source "${ADM_SCRIPTS}/log.sh" || true
fi
if [ -f "${ADM_SCRIPTS}/ui.sh" ]; then
    # shellcheck disable=SC1090
    source "${ADM_SCRIPTS}/ui.sh" || true
fi

# Defaults (safe defaults if not provided by env.sh)
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_TMP:=${ADM_ROOT}/tmp}"
: "${ADM_CACHE:=${ADM_ROOT}/cache}"
: "${ADM_LOGS:=${ADM_ROOT}/logs}"
: "${ADM_BUILD:=${ADM_ROOT}/build}"
: "${ADM_CONFIG_DIR:=${ADM_ROOT}/config}"
: "${ADM_JOB_LOCK:=${ADM_ROOT}/.scheduler.lock}"
: "${ADM_CLEAN_MODE:=safe}"
: "${ADM_CLEAN_REPORT:=${ADM_LOGS}/clean-report.log}"
: "${ADM_KEEP_LOGS_DAYS:=7}"
: "${ADM_KEEP_BUILDS_DAYS:=3}"
: "${ADM_FORCE:=false}"
: "${ADM_DRY_RUN:=false}"
: "${ADM_ONLY:="tmp,cache,logs,builds,orphans"}"
: "${ADM_UI_REFRESH:=0.2}"

# Lockfile for clean execution
_CLEAN_LOCKFILE="${ADM_ROOT}/.clean_lock"

# Internal counters
declare -i CLEAN_REMOVED_COUNT=0
declare -i CLEAN_REMOVED_BYTES=0
declare -A CLEAN_DETAILS

# Ensure directories exist (create safe defaults)
mkdir -p "$ADM_TMP" "$ADM_CACHE" "$ADM_LOGS" "$ADM_BUILD" 2>/dev/null || true

# Helpers: logging fallback if log.sh not loaded
_have_log=false
if declare -f log_info >/dev/null 2>&1; then
    _have_log=true
fi
_log_info() {
    if $_have_log; then log_info "clean" "" "$*"; else printf '%s\n' "[INFO] $*"; fi
}
_log_warn() {
    if $_have_log; then log_warn "clean" "" "$*"; else printf '%s\n' "[WARN] $*"; fi
}
_log_error() {
    if $_have_log; then log_error "clean" "" "$*"; else printf '%s\n' "[ERROR] $*"; fi
}

# Safety: ensure path is inside ADM_ROOT
_safe_within_root() {
    local p
    p="$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")"
    case "$p" in
        "$ADM_ROOT"* ) return 0 ;;
        * ) return 1 ;;
    esac
}

# Safe remove: do not follow symlinks outside ADM_ROOT, support dry-run
_safe_rm() {
    local path="$1"
    if [ -z "$path" ]; then return 0; fi
    if ! _safe_within_root "$path"; then
        _log_warn "Skipping removal outside ADM_ROOT: $path"
        return 1
    fi
    if [ "$ADM_DRY_RUN" = "true" ]; then
        _log_info "[DRY-RUN] Would remove: $path"
        CLEAN_DETAILS["$path"]=dryrun
        return 0
    fi
    # compute size before removing
    local bytes=0
    if [ -e "$path" ]; then
        bytes=$(du -sb "$path" 2>/dev/null | awk '{print $1}' || echo 0)
    fi
    # remove safely
    if [ -d "$path" ] && [ ! -L "$path" ]; then
        rm -rf -- "$path" || { _log_warn "Failed to remove dir $path"; return 1; }
    else
        rm -f -- "$path" || { _log_warn "Failed to remove file $path"; return 1; }
    fi
    CLEAN_REMOVED_COUNT=$((CLEAN_REMOVED_COUNT+1))
    CLEAN_REMOVED_BYTES=$((CLEAN_REMOVED_BYTES+bytes))
    CLEAN_DETAILS["$path"]=$bytes
    _log_info "Removed: $path (${bytes} bytes)"
    return 0
}

# Acquire exclusive lock to avoid concurrent cleaners
_acquire_clean_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$_CLEAN_LOCKFILE" || return 1
        flock -n 9 || return 1
        return 0
    else
        # simple pid file
        if [ -f "$_CLEAN_LOCKFILE" ]; then
            local otherpid
            otherpid=$(cat "$_CLEAN_LOCKFILE" 2>/dev/null || echo "")
            if [ -n "$otherpid" ] && kill -0 "$otherpid" 2>/dev/null; then
                return 1
            fi
        fi
        printf '%s' "$BASHPID" > "$_CLEAN_LOCKFILE" || return 1
        return 0
    fi
}
_release_clean_lock() {
    if command -v flock >/dev/null 2>&1; then
        # close fd 9
        exec 9>&- 2>/dev/null || true
        return 0
    else
        rm -f "$_CLEAN_LOCKFILE" 2>/dev/null || true
        return 0
    fi
}

# Check scheduler integration: don't clean when scheduler indicates active jobs
_scheduler_check() {
    # If scheduler lock exists and process alive, avoid destructive cleaning
    if [ -f "$ADM_JOB_LOCK" ]; then
        local pid
        pid=$(cat "$ADM_JOB_LOCK" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            _log_warn "Scheduler appears active (pid=$pid). Aborting clean to avoid interfering with running jobs."
            return 1
        fi
    fi
    return 0
}

# Age helper: file age in seconds
_file_age_seconds() {
    local f="$1"
    if [ ! -e "$f" ]; then echo 0; return; fi
    local now
    now=$(date +%s)
    local mtime
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    echo $(( now - mtime ))
}

# Convert days to seconds
_days_to_seconds() { echo $(( $1 * 86400 )); }

# =================== Cleaning actions ===================

clean_tmp() {
    _log_info "Cleaning temporary directories: $ADM_TMP and /tmp/adm-*"
    # ADM_TMP
    if [ -d "$ADM_TMP" ]; then
        for item in "$ADM_TMP"/*; do
            [ -e "$item" ] || continue
            _safe_rm "$item" || _log_warn "Could not remove $item"
        done
    fi
    # /tmp/adm-*
    for t in /tmp/adm-*; do
        [ -e "$t" ] || continue
        _safe_rm "$t" || _log_warn "Could not remove $t"
    done
}

clean_cache() {
    _log_info "Cleaning cache directory: $ADM_CACHE"
    if [ ! -d "$ADM_CACHE" ]; then
        _log_info "Cache directory not present: $ADM_CACHE"
        return 0
    fi
    local ttl_seconds
    ttl_seconds=$(_days_to_seconds ${ADM_KEEP_BUILDS_DAYS:-3})
    for f in "$ADM_CACHE"/*; do
        [ -e "$f" ] || continue
        # Skip protected files
        if [ -f "$f/.protected" ] || [ -f "$f/.keep" ]; then
            _log_info "Skipping protected cache: $f"
            continue
        fi
        local age
        age=$(_file_age_seconds "$f")
        if [ "$age" -ge "$ttl_seconds" ] || [ "${ADM_CLEAN_MODE}" = "purge" ] || [ "${ADM_CLEAN_MODE}" = "deep" ]; then
            _safe_rm "$f" || _log_warn "Failed to remove cache $f"
        fi
    done
}

clean_logs() {
    _log_info "Cleaning logs older than ${ADM_KEEP_LOGS_DAYS} days in $ADM_LOGS"
    if [ ! -d "$ADM_LOGS" ]; then _log_info "No logs directory: $ADM_LOGS"; return 0; fi
    local cutoff_days=${ADM_KEEP_LOGS_DAYS}
    local cutoff_seconds=$(_days_to_seconds $cutoff_days)
    for lf in "$ADM_LOGS"/*.log; do
        [ -f "$lf" ] || continue
        local age
        age=$(_file_age_seconds "$lf")
        if [ "$age" -ge "$cutoff_seconds" ] || [ "${ADM_CLEAN_MODE}" = "purge" ]; then
            # Avoid deleting current session logs
            if [ "$lf" = "${ADM_LOGS}/${ADM_LOG_SESSION}.log" ]; then
                _log_info "Skipping current session log: $lf"
                continue
            fi
            _safe_rm "$lf" || _log_warn "Failed to remove log $lf"
        fi
    done
    # rotate via log.sh if available
    if declare -f log_rotate >/dev/null 2>&1; then
        if [ "$ADM_DRY_RUN" = "true" ]; then
            _log_info "[DRY-RUN] Would invoke log_rotate"
        else
            log_rotate || _log_warn "log_rotate returned non-zero"
        fi
    fi
}

clean_builds() {
    _log_info "Cleaning old or incomplete builds in $ADM_BUILD"
    [ -d "$ADM_BUILD" ] || { _log_info "No build dir: $ADM_BUILD"; return 0; }
    local cutoff_seconds=$(_days_to_seconds ${ADM_KEEP_BUILDS_DAYS:-3})
    for bd in "$ADM_BUILD"/*; do
        [ -e "$bd" ] || continue
        # identify incomplete builds: presence of .incomplete or .lock or missing build.success
        if [ -f "$bd/.incomplete" ] || [ -f "$bd/.failed" ] || [ -f "$bd/.lock" ] || [ ! -f "$bd/build.success" ]; then
            _log_info "Found candidate incomplete build: $bd"
            if [ "${ADM_CLEAN_MODE}" = "safe" ]; then
                # only remove if older than cutoff
                local age
                age=$(_file_age_seconds "$bd")
                if [ "$age" -ge "$cutoff_seconds" ]; then
                    _safe_rm "$bd" || _log_warn "Failed to remove build $bd"
                else
                    _log_info "Skipping recent incomplete build: $bd"
                fi
            else
                # deep or purge: remove unconditionally
                _safe_rm "$bd" || _log_warn "Failed to remove build $bd"
            fi
        fi
    done
}

clean_orphans() {
    _log_info "Cleaning orphaned directories in $ADM_ROOT"
    # orphan = dir in build/ or repo/ without a corresponding entry in repo or repo metadata
    # simple heuristic: directories in ADM_BUILD without a matching repo/<name>
    for d in "$ADM_BUILD"/*; do
        [ -d "$d" ] || continue
        local name
        name=$(basename "$d")
        if [ ! -d "$ADM_ROOT/repo/$name" ]; then
            _log_info "Orphan build dir: $d"
            _safe_rm "$d" || _log_warn "Failed to remove orphan $d"
        fi
    done
}

# Selective cleaning: parse ADM_ONLY which is comma-separated list
_should_run_target() {
    local target="$1"
    IFS=',' read -r -a ots <<<"$ADM_ONLY"
    for t in "${ots[@]}"; do
        if [ "$t" = "$target" ] || [ "$t" = "all" ]; then
            return 0
        fi
    done
    return 1
}

# Summary reporter
_clean_report() {
    local report_file="${ADM_CLEAN_REPORT}"
    local freed_human
    freed_human=$(numfmt --to=iec --suffix=B "$CLEAN_REMOVED_BYTES" 2>/dev/null || echo "${CLEAN_REMOVED_BYTES} bytes")
    {
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] Clean mode=${ADM_CLEAN_MODE} dry-run=${ADM_DRY_RUN} removed_count=${CLEAN_REMOVED_COUNT} removed_bytes=${CLEAN_REMOVED_BYTES}"
        for p in "${!CLEAN_DETAILS[@]}"; do
            echo "  ${p} => ${CLEAN_DETAILS[$p]}"
        done
        echo "Summary: removed ${CLEAN_REMOVED_COUNT} items, freed ${freed_human}"
    } >> "$report_file"

    _log_info "Clean finished: removed=${CLEAN_REMOVED_COUNT} freed=${freed_human} report=${report_file}"
}

# Safety prompt for purge
_confirm_purge() {
    if [ "$ADM_FORCE" = "true" ]; then
        return 0
    fi
    printf 'Purge mode requested. This will remove logs, caches and builds under %s.\n' "$ADM_ROOT"
    printf 'Type YES to confirm: '
    read -r ans
    if [ "$ans" != "YES" ]; then
        _log_warn "Purge aborted by user"
        return 1
    fi
    return 0
}

# Parse args
_print_usage() {
    cat <<EOF
Usage: $(basename "$0") [--mode safe|deep|purge] [--only <comma-list>] [--dry-run] [--force] [--help]
Options:
  --mode       choose clean mode: safe (default), deep, purge
  --only       comma-separated targets: tmp,cache,logs,builds,orphans,all
  --dry-run    show actions without deleting
  --force      skip interactive confirmation for purge
  --help       show this help
EOF
}

_parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mode) shift; ADM_CLEAN_MODE=${1:-safe}; shift ;;
            --mode=*) ADM_CLEAN_MODE=${1#--mode=} ; shift ;;
            --only) shift; ADM_ONLY=${1:-$ADM_ONLY}; shift ;;
            --only=*) ADM_ONLY=${1#--only=} ; shift ;;
            --dry-run) ADM_DRY_RUN=true; shift ;;
            --force) ADM_FORCE=true; shift ;;
            --yes) ADM_FORCE=true; shift ;;
            --help|-h) _print_usage; exit 0 ;;
            *) _log_warn "Unknown arg: $1"; _print_usage; exit 2 ;;
        esac
    done
}

# Main controller
clean_main() {
    _parse_args "$@"

    # Acquire lock
    if ! _acquire_clean_lock; then
        _log_warn "Another clean.sh appears to be running (lock ${_CLEAN_LOCKFILE}). Exiting."
        return 1
    fi

    # scheduler check
    if ! _scheduler_check; then
        _log_warn "Scheduler active; aborting clean to avoid interference."
        _release_clean_lock
        return 1
    fi

    # Purge confirmation
    if [ "${ADM_CLEAN_MODE}" = "purge" ]; then
        if ! _confirm_purge; then
            _release_clean_lock
            return 1
        fi
    fi

    _log_info "Starting clean: mode=${ADM_CLEAN_MODE} only=${ADM_ONLY} dry-run=${ADM_DRY_RUN}"

    # Run selected targets
    if _should_run_target tmp; then clean_tmp; fi
    if _should_run_target cache; then clean_cache; fi
    if _should_run_target logs; then clean_logs; fi
    if _should_run_target builds; then clean_builds; fi
    if _should_run_target orphans; then clean_orphans; fi

    # summary and release lock
    _clean_report
    _release_clean_lock
    return 0
}

# If script executed directly, run clean_main
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    clean_main "$@"
fi

# Export public functions
export -f clean_main clean_tmp clean_cache clean_logs clean_builds clean_orphans _safe_rm
