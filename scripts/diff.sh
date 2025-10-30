#!/usr/bin/env bash
# diff.sh - Comparison and patch management for ADM Build System
# Location: /usr/src/adm/scripts/diff.sh
# Purpose: compare scripts/directories, generate unified patch files, allow editing and applying patches
# SPDX-License-Identifier: MIT

# Guard to allow sourcing
: "${ADM_DIFF_SH_LOADED:-}" || ADM_DIFF_SH_LOADED=0
if [ "$ADM_DIFF_SH_LOADED" -eq 1 ]; then
    return 0
fi
ADM_DIFF_SH_LOADED=1

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

# Defaults
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_PATCHES:=${ADM_ROOT}/patches}"
: "${ADM_REPORTS:=${ADM_ROOT}/reports}"
: "${ADM_DIFF_FORMAT:=color}"   # color, plain, json, summary
: "${ADM_DIFF_CONTEXT:=3}"
: "${ADM_DIFF_IGNORE_SPACE:=false}"
: "${ADM_DIFF_DRY_RUN:=false}"
: "${ADM_EDITOR:=${EDITOR:-vi}}"

# Ensure dirs
mkdir -p "$ADM_PATCHES" "$ADM_REPORTS" 2>/dev/null || true

# Logging fallbacks
_have_log=false
if declare -f log_info >/dev/null 2>&1; then _have_log=true; fi
_log_info() { if $_have_log; then log_info "diff" "" "$*"; else printf '%s\n' "[INFO] $*"; fi }
_log_warn() { if $_have_log; then log_warn "diff" "" "$*"; else printf '%s\n' "[WARN] $*"; fi }
_log_error() { if $_have_log; then log_error "diff" "" "$*"; else printf '%s\n' "[ERROR] $*"; fi }

# Safety: ensure path is inside ADM_ROOT
_safe_within_root() {
    local p
    p="$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")"
    case "$p" in
        "$ADM_ROOT"* ) return 0 ;;
        * ) return 1 ;;
    esac
}

# Helper: check command exists
_check_cmd() {
    command -v "$1" >/dev/null 2>&1 || return 1
}

# Compute sha256
_hash_file() {
    local f="$1"
    if _check_cmd sha256sum; then
        sha256sum "$f" | awk '{print $1}'
    elif _check_cmd shasum; then
        shasum -a 256 "$f" | awk '{print $1}'
    else
        echo "-"
    fi
}

# Make patch name
_patch_name() {
    local sfx="$1"
    local base
    base="$(date +'%Y-%m-%d_%H%M%S')_${sfx}.patch"
    echo "$ADM_PATCHES/$base"
}

# Write report file helper
_write_report() {
    local mode="$1" reportfile="$2" content="$3"
    mkdir -p "$ADM_REPORTS" 2>/dev/null || true
    printf '%s\n' "$content" > "$reportfile"
    _log_info "Report written: $reportfile"
}

# Colorize helpers
_diff_colorize_line() {
    local line="$1"
    case "$line" in
        +++*|---*|@@* ) printf '%s\n' "$line" ;;
        +*) printf '%b%s%b\n' "\e[1;32m" "$line" "\e[0m" ;;
        -*) printf '%b%s%b\n' "\e[1;31m" "$line" "\e[0m" ;;
        *) printf '%s\n' "$line" ;;
    esac
}

# Core: diff two files, return patch content (stdout)
_diff_files_to_stdout() {
    local a="$1" b="$2" context="$3"
    local diffcmd=(diff -u -p -U "$context" -- "$a" "$b")
    if [ "$ADM_DIFF_IGNORE_SPACE" = "true" ]; then
        diffcmd=(diff -u -b -B -p -U "$context" -- "$a" "$b")
    fi
    if _check_cmd diff; then
        "${diffcmd[@]}" 2>/dev/null || return 0
    else
        _log_error "diff not available"
        return 2
    fi
}

# Compare two scripts/files and optionally save patch
diff_scripts() {
    local f1="$1" f2="$2" context="${3:-$ADM_DIFF_CONTEXT}"
    if [ -z "$f1" ] || [ -z "$f2" ]; then _log_error "diff_scripts requires two files"; return 2; fi
    if ! _safe_within_root "$f1" || ! _safe_within_root "$f2"; then _log_error "Files must be inside $ADM_ROOT"; return 2; fi
    if [ ! -f "$f1" ] || [ ! -f "$f2" ]; then _log_error "One of the files does not exist"; return 2; fi

    local patch
    patch="$(mktemp)"
    if [ "$ADM_DIFF_DRY_RUN" = "true" ]; then
        _log_info "[DRY-RUN] Would create diff between $f1 and $f2"
        _diff_files_to_stdout "$f1" "$f2" "$context" || true
        rm -f "$patch" 2>/dev/null || true
        return 0
    fi

    _diff_files_to_stdout "$f1" "$f2" "$context" > "$patch" || true
    if [ ! -s "$patch" ]; then
        _log_info "No differences between $f1 and $f2"
        rm -f "$patch" 2>/dev/null || true
        return 0
    fi
    local sfx
    sfx="$(basename "$f1" .sh)-to-$(basename "$f2" .sh)"
    local pfile
    pfile="$(_patch_name "$sfx")"
    mv -f "$patch" "$pfile"
    chmod 0644 "$pfile" 2>/dev/null || true
    _log_info "Patch created: $pfile"
    printf '%s\n' "$pfile"
}

# Compare two directories and create series of patches
diff_codes() {
    local d1="$1" d2="$2" context="${3:-$ADM_DIFF_CONTEXT}"
    if [ -z "$d1" ] || [ -z "$d2" ]; then _log_error "diff_codes requires two directories"; return 2; fi
    if ! _safe_within_root "$d1" || ! _safe_within_root "$d2"; then _log_error "Directories must be inside $ADM_ROOT"; return 2; fi
    if [ ! -d "$d1" ] || [ ! -d "$d2" ]; then _log_error "One of the directories does not exist"; return 2; fi

    mkdir -p "$ADM_PATCHES" 2>/dev/null || true
    local series_file
    series_file="$ADM_PATCHES/series_$(date +%Y%m%d_%H%M%S).list"
    : > "$series_file"

    # Use rsync if available
    if _check_cmd rsync; then
        local changes
        changes=$(rsync -rcn --delete --out-format='%n' "$d1/" "$d2/" 2>/dev/null || true)
        while IFS= read -r rel; do
            [ -z "$rel" ] && continue
            local f1="$d1/$rel"
            local f2="$d2/$rel"
            if [ -f "$f1" ] && [ -f "$f2" ]; then
                local p
                p=$(diff_scripts "$f1" "$f2" "$context") || true
                if [ -n "$p" ]; then echo "$p" >> "$series_file"; fi
            else
                local pfile
                pfile="$(_patch_name "$(basename "$rel" | tr '/' '-')")"
                {
                    printf '*** structural change: %s\n' "$rel"
                } > "$pfile"
                echo "$pfile" >> "$series_file"
                _log_info "Recorded structural change as patch entry: $pfile"
            fi
        done <<<"$changes"
    else
        _log_warn "rsync unavailable; falling back to find+diff traversal"
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            local rel
            rel=${f#"$d1/"}
            if [ -f "$d2/$rel" ]; then
                local p
                p=$(diff_scripts "$f" "$d2/$rel" "$context") || true
                if [ -n "$p" ]; then echo "$p" >> "$series_file"; fi
            else
                local pfile
                pfile="$(_patch_name "$(basename "$rel" | tr '/' '-')")"
                : > "$pfile"
                echo "$pfile" >> "$series_file"
                _log_info "Added orphan patch entry for $rel"
            fi
        done < <(find "$d1" -type f)
    fi

    _log_info "Series file created: $series_file"
    printf '%s\n' "$series_file"
}
