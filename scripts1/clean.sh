#!/usr/bin/env bash
# /usr/src/adm/scripts/clean.sh
# Smart cleaner for ADM Build System
# Modes: --light (default), --deep, --purge, --analyze
# Options: --confirm (ask before destructive), --dry-run (show only)
# Requires: lib.sh (for info/ok/warn/fatal/acquire_lock/release_lock)
set -euo pipefail

# ---- load libs if available (idempotent) ----
if [ -n "${ADM_SCRIPTS_DIR-}" ] && [ -f "${ADM_SCRIPTS_DIR}/lib.sh" ]; then
  # shellcheck disable=SC1090
  source "${ADM_SCRIPTS_DIR}/lib.sh"
else
  # minimal fallback logging if lib not present
  timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
  info() { printf "[INFO]  %s\n" "$*"; }
  ok()   { printf "[ OK ]  %s\n" "$*"; }
  warn() { printf "[WARN]  %s\n" "$*"; }
  fatal(){ printf "[ERR]   %s\n" "$*"; exit 1; }
  acquire_lock() { :
  }
  release_lock() { :
  }
fi

# Defaults (respect ENV overrides)
ADM_ROOT=${ADM_ROOT:-/usr/src/adm}
ADM_BUILD=${ADM_BUILD:-"${ADM_ROOT}/build"}
ADM_DISTFILES=${ADM_DISTFILES:-"${ADM_ROOT}/distfiles"}
ADM_BINCACHE=${ADM_BINCACHE:-"${ADM_ROOT}/binary-cache"}
ADM_LOGS=${ADM_LOGS:-"${ADM_ROOT}/logs"}
ADM_STATE=${ADM_STATE:-"${ADM_ROOT}/state"}
ADM_METAFILES=${ADM_METAFILES:-"${ADM_ROOT}/metafiles"}
ADM_UPDATES=${ADM_UPDATES:-"${ADM_ROOT}/updates"}
ADM_LOG_ROTATE_DIR="${ADM_LOGS}/rotated"
ADM_KEEP_DIST_PER_PKG=${ADM_KEEP_DIST_PER_PKG:-3}
ADM_KEEP_BIN_PER_PKG=${ADM_KEEP_BIN_PER_PKG:-5}
ADM_KEEP_LOG_DAYS=${ADM_KEEP_LOG_DAYS:-7}
ADM_VERBOSE=${ADM_VERBOSE:-1}

CLEAN_MODE="light"
CONFIRM=0
DRY_RUN=0
FORCE=0

# whitelist (never remove these roots)
WHITELIST=(
  "${ADM_ROOT}/metafiles"
  "${ADM_ROOT}/scripts"
  "${ADM_ROOT}/state"
  "${ADM_ROOT}/updates"
)

# lock file for cleaning
CLEAN_LOCK="${ADM_STATE}/clean.lock"

# trap to release lock
_cleanup_trap() {
  release_lock 2>/dev/null || true
}
trap _cleanup_trap EXIT INT TERM

# ---- helpers ----
_read_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --light) CLEAN_MODE="light"; shift ;;
      --deep) CLEAN_MODE="deep"; shift ;;
      --purge) CLEAN_MODE="purge"; shift ;;
      --analyze) CLEAN_MODE="analyze"; shift ;;
      --confirm) CONFIRM=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --force) FORCE=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: clean.sh [--light|--deep|--purge|--analyze] [--confirm] [--dry-run] [--force]

Modes:
  --light    : remove build temp dirs, stale locks, tmp files (default)
  --deep     : plus: clean distfiles not referenced, binary-cache old items, rotate logs
  --purge    : destructive: remove build/distfiles/binary-cache/logs (keeps metafiles & state)
  --analyze  : don't remove anything, only report candidates and sizes

Options:
  --confirm  : ask user before deleting (when interactive)
  --dry-run  : show actions but do not perform deletions
  --force    : bypass some safety checks (use carefully)
EOF
        exit 0
        ;;
      *)
        warn "Unknown arg: $1"
        shift
        ;;
    esac
  done
}

_bytes_to_human() {
  # input: bytes; output human readable
  awk 'function human(x){
    s="BKMGTPEZY"; i=1;
    while(x>=1024 && i<length(s)){ x/=1024; i++ }
    if(i==1) printf "%.0fB", x; else printf "%.1f%cB", x, substr(s,i,1)
  }{human($1)}' <<<"$1"
}

_du_bytes() {
  # safe du: returns bytes for path
  if [ -e "$1" ]; then
    du -sb "$1" 2>/dev/null | awk '{print $1}'
  else
    echo 0
  fi
}

_confirm_or_abort() {
  if [ "$DRY_RUN" -eq 1 ]; then
    info "DRY-RUN: no changes will be made"
    return 0
  fi
  if [ "$CONFIRM" -eq 1 ]; then
    printf "Confirm: %s [y/N]: " "$1"
    read -r ans || ans="n"
    case "$ans" in
      y|Y) return 0 ;;
      *) fatal "Aborted by user." ;;
    esac
  fi
}

_in_whitelist() {
  local p="$1"
  for w in "${WHITELIST[@]}"; do
    case "$p" in
      "$w" | "$w"/*) return 0 ;;
    esac
  done
  return 1
}

# returns basenames of distfiles referenced by metafiles (comma/newline separated)
_list_referenced_distfiles() {
  # search for source_url= in INI metafiles
  # support both formats: key=... or Source URL: style (we use INI)
  grep -hR "^[[:space:]]*source_url=" "${ADM_METAFILES}" 2>/dev/null || true
}

# build map of referenced basenames
_build_referenced_map() {
  # create temp file with basenames
  local tmpf
  tmpf=$(mktemp)
  # parse lines like: source_url=https://.../name-version.tar.xz
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # extract URL
    url=$(echo "$line" | sed -E 's/^[[:space:]]*source_url=[[:space:]]*//')
    base=$(basename "$url")
    echo "$base" >> "$tmpf"
  done < <(_list_referenced_distfiles)
  # also include updates dir metafiles
  if [ -d "${ADM_UPDATES}" ]; then
    grep -hR "^[[:space:]]*source_url=" "${ADM_UPDATES}" 2>/dev/null || true | sed -E 's/^[[:space:]]*source_url=[[:space:]]*//' | xargs -r -n1 basename >> "$tmpf" || true
  fi
  sort -u "$tmpf"
  rm -f "$tmpf"
}

# find candidate distfiles to remove (not referenced and older)
_find_dist_candidates() {
  local keep_per=${ADM_KEEP_DIST_PER_PKG}
  # group by name prefix (strip -version)
  # approach: for each file, determine package key (name without version heuristics)
  # simple heuristic: take filename up to first digit+dot sequence or last '-' before version numbers
  # fallback: use full basename grouping by name part before first '-' with digit
  find "${ADM_DISTFILES}" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null || true
}

# ---- core cleaning actions ----

clean_build_dirs() {
  info "Cleaning build directories under ${ADM_BUILD}..."
  local removed=0 freed=0
  if [ ! -d "${ADM_BUILD}" ]; then
    info "No build directory found; skipping."
    return 0
  fi
  # find build dirs older than 1 day (keep very recent)
  mapfile -t dirs < <(find "${ADM_BUILD}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)
  for d in "${dirs[@]:-}"; do
    # skip if in whitelist
    _in_whitelist "$d" && continue
    # skip if adm.lock exists and indicates build in progress in this dir (best-effort)
    if [ -f "${ADM_STATE}/adm.lock" ] && lsof -t +D "$d" >/dev/null 2>&1; then
      warn "Build dir in use (skipping): $d"
      continue
    fi
    size_before=$(_du_bytes "$d")
    if [ "$DRY_RUN" -eq 1 ]; then
      info "DRY-RUN remove: $d ($( _bytes_to_human "$size_before" ))"
    else
      rm -rf "$d"
      removed=$((removed+1))
      freed=$((freed + size_before))
    fi
  done
  ok "Removed ${removed} build dirs (freed $( _bytes_to_human "$freed" ))"
}

clean_tmp_files() {
  info "Cleaning temporary files (pattern: *.tmp, *.lock.old, *.bak) in ${ADM_BUILD} and ${ADM_ROOT}..."
  local patterns=( "*.tmp" "*.lock" "*.lock.old" "*.bak" )
  local total_removed=0 total_freed=0
  for p in "${patterns[@]}"; do
    mapfile -t files < <(find "${ADM_BUILD}" "${ADM_ROOT}" -type f -name "$p" -print 2>/dev/null || true)
    for f in "${files[@]:-}"; do
      # protect manifests/state/etc
      _in_whitelist "$f" && continue
      size=$(_du_bytes "$f")
      if [ "$DRY_RUN" -eq 1 ]; then
        info "DRY-RUN remove: $f ($( _bytes_to_human "$size" ))"
      else
        rm -f "$f"
        total_removed=$((total_removed+1))
        total_freed=$((total_freed+size))
      fi
    done
  done
  ok "Temp cleanup: removed ${total_removed} files (freed $( _bytes_to_human "$total_freed" ))"
}

clean_distfiles_deep() {
  info "Analyzing distfiles in ${ADM_DISTFILES}..."
  if [ ! -d "${ADM_DISTFILES}" ]; then
    info "No distfiles dir; skipping."
    return 0
  fi
  # build referenced set
  local tmp_ref tmp_keep files removed freed
  tmp_ref=$(mktemp)
  _build_referenced_map > "$tmp_ref" 2>/dev/null || true
  # create an associative array (bash 4+) of referenced names
  declare -A refmap
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    refmap["$b"]=1
  done < "$tmp_ref"
  rm -f "$tmp_ref"

  # heuristic: for each file in distfiles, if not referenced and older than N days -> candidate
  removed=0; freed=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    base=$(basename "$f")
    # if referenced, keep
    if [ -n "${refmap["$base"]-}" ]; then
      continue
    fi
    size=$(_du_bytes "$f")
    if [ "$DRY_RUN" -eq 1 ]; then
      info "DRY-RUN remove distfile: $f ($( _bytes_to_human "$size" ))"
    else
      rm -f "$f" && removed=$((removed+1)) && freed=$((freed+size))
    fi
  done < <(find "${ADM_DISTFILES}" -type f -printf '%p\n' 2>/dev/null || true)

  ok "Distfiles cleanup: removed ${removed} files (freed $( _bytes_to_human "$freed" ))"
}

clean_bincache_deep() {
  info "Cleaning binary cache ${ADM_BINCACHE} (keeping ${ADM_KEEP_BIN_PER_PKG} per pkg)..."
  if [ ! -d "${ADM_BINCACHE}" ]; then
    info "No binary-cache; skipping."
    return 0
  fi
  # for each package prefix (heuristic split by name-version.tar.gz or pkgid)
  removed=0; freed=0
  # We simply keep newest N files per filename prefix (prefix before first dash)
  # Build map of prefix -> files (sorted by mtime)
  while IFS= read -r f; do
    base=$(basename "$f")
    prefix="${base%%-*}"
    # fallback if no dash
    [ -z "$prefix" ] && prefix="$base"
    echo "$f" >> "/tmp/adm_bincache_${prefix}.list" 2>/dev/null || true
  done < <(find "${ADM_BINCACHE}" -type f -printf '%p\n' 2>/dev/null || true)

  for list in /tmp/adm_bincache_*.list; do
    [ -f "$list" ] || continue
    mapfile -t files < <(sort -r -n -k1,1 <(xargs -d'\n' stat -c '%Y %n' < "$list") 2>/dev/null | awk '{print $2}')
    # keep first N
    idx=0
    for f in "${files[@]}"; do
      idx=$((idx+1))
      if [ "$idx" -gt "${ADM_KEEP_BIN_PER_PKG}" ]; then
        size=$(_du_bytes "$f")
        if [ "$DRY_RUN" -eq 1 ]; then
          info "DRY-RUN remove bin-cache: $f ($( _bytes_to_human "$size" ))"
        else
          rm -f "$f" && removed=$((removed+1)) && freed=$((freed+size))
        fi
      fi
    done
    rm -f "$list"
  done

  ok "Binary-cache cleanup: removed ${removed} files (freed $( _bytes_to_human "$freed" ))"
}

clean_logs_rotate() {
  info "Rotating/moving logs older than ${ADM_LOG_KEEP_DAYS:-${ADM_KEEP_LOG_DAYS}} days..."
  mkdir -p "${ADM_LOG_ROTATE_DIR}"
  local moved=0 size=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ "${DRY_RUN}" -eq 1 ]; then
      info "DRY-RUN move log: $f"
    else
      mv -f "$f" "${ADM_LOG_ROTATE_DIR}/" && moved=$((moved+1))
      size=$((size + $(_du_bytes "${ADM_LOG_ROTATE_DIR}/$(basename "$f")")))
    fi
  done < <(find "${ADM_LOGS}" -maxdepth 1 -type f -mtime +"${ADM_KEEP_LOG_DAYS}" -name '*.log' 2>/dev/null || true)
  ok "Logs rotated: moved ${moved} files"
}

clean_state_locks() {
  info "Cleaning stale locks in ${ADM_STATE}..."
  local removed=0 freed=0
  # consider lock files older than 1 day
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # check if PID inside is alive (best-effort)
    pid=$(sed -n '1p' "$f" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      warn "Lock in use (skipping): $f (pid $pid alive)"
      continue
    fi
    size=$(_du_bytes "$f")
    if [ "$DRY_RUN" -eq 1 ]; then
      info "DRY-RUN remove stale lock: $f"
    else
      rm -f "$f" && removed=$((removed+1)) && freed=$((freed+size))
    fi
  done < <(find "${ADM_STATE}" -type f -name '*.lock' -mtime +1 -print 2>/dev/null || true)
  ok "Locks cleanup: removed ${removed} files (freed $( _bytes_to_human "$freed" ))"
}

analyze_space() {
  info "Analyzing space usage (dry-run report)..."
  local b_build b_dist b_bin b_logs total
  b_build=$(_du_bytes "${ADM_BUILD}")
  b_dist=$(_du_bytes "${ADM_DISTFILES}")
  b_bin=$(_du_bytes "${ADM_BINCACHE}")
  b_logs=$(_du_bytes "${ADM_LOGS}")
  total=$((b_build + b_dist + b_bin + b_logs))
  printf "\n─────────────────────────────────────────────\n"
  printf "Analysis (no removal)\n"
  printf "─────────────────────────────────────────────\n"
  printf "build/:        %10s\n" "$( _bytes_to_human "$b_build" )"
  printf "distfiles/:    %10s\n" "$( _bytes_to_human "$b_dist" )"
  printf "binary-cache/: %10s\n" "$( _bytes_to_human "$b_bin" )"
  printf "logs/:         %10s\n" "$( _bytes_to_human "$b_logs" )"
  printf "─────────────────────────────────────────────\n"
  printf "Total:         %10s\n\n" "$( _bytes_to_human "$total" )"
}

# main entry
main() {
  _read_args "$@"

  # show header via lib.sh (if available)
  if type show_header >/dev/null 2>&1; then
    show_header
  fi

  # ensure state dir exists
  mkdir -p "${ADM_STATE}"

  # safety: if adm.lock exists and not forced, do not purge build dirs
  if [ -f "${ADM_STATE}/adm.lock" ] && [ "${FORCE}" -eq 0 ] && [ "${CLEAN_MODE}" = "purge" ]; then
    fatal "adm.lock present: system busy. Use --force to override."
  fi

  # acquire lock for cleaning operations
  acquire_lock

  # mode analyze: only report
  if [ "${CLEAN_MODE}" = "analyze" ]; then
    analyze_space
    release_lock
    return 0
  fi

  # CONFIRM for destructive modes
  if [ "${CLEAN_MODE}" = "purge" ] && [ "${CONFIRM}" -eq 0 ] && [ "${DRY_RUN}" -eq 0 ]; then
    warn "You are about to run PURGE mode (destructive). Use --confirm to proceed interactively or --dry-run to simulate."
    release_lock
    exit 1
  fi

  # Begin actions based on mode
  local size_before size_after freed_total
  size_before=$(_du_bytes "${ADM_ROOT}")

  # light: always do build dirs, temp files, stale locks
  clean_build_dirs
  clean_tmp_files
  clean_state_locks

  if [ "${CLEAN_MODE}" = "deep" ] || [ "${CLEAN_MODE}" = "purge" ]; then
    # rotate logs older than threshold
    clean_logs_rotate
    # deep: distfiles & binary-cache cleaning
    if [ "${CLEAN_MODE}" = "deep" ]; then
      clean_distfiles_deep
      clean_bincache_deep
    fi
    # purge: remove everything except whitelist
    if [ "${CLEAN_MODE}" = "purge" ]; then
      info "Purge mode: removing build, distfiles, binary-cache, logs (excluding whitelist)"
      # build
      if [ -d "${ADM_BUILD}" ]; then
        if [ "${DRY_RUN}" -eq 1 ]; then
          info "DRY-RUN: rm -rf ${ADM_BUILD}/*"
        else
          find "${ADM_BUILD}" -mindepth 1 -maxdepth 1 -exec rm -rf {} \; 2>/dev/null || true
        fi
      fi
      # distfiles
      if [ -d "${ADM_DISTFILES}" ]; then
        if [ "${DRY_RUN}" -eq 1 ]; then
          info "DRY-RUN: rm -rf ${ADM_DISTFILES}/*"
        else
          find "${ADM_DISTFILES}" -mindepth 1 -maxdepth 1 -exec rm -rf {} \; 2>/dev/null || true
        fi
      fi
      # binary-cache
      if [ -d "${ADM_BINCACHE}" ]; then
        if [ "${DRY_RUN}" -eq 1 ]; then
          info "DRY-RUN: rm -rf ${ADM_BINCACHE}/*"
        else
          find "${ADM_BINCACHE}" -mindepth 1 -maxdepth 1 -exec rm -rf {} \; 2>/dev/null || true
        fi
      fi
      # logs (careful: preserve rotated dir)
      if [ -d "${ADM_LOGS}" ]; then
        if [ "${DRY_RUN}" -eq 1 ]; then
          info "DRY-RUN: remove logs in ${ADM_LOGS} except ${ADM_LOG_ROTATE_DIR}"
        else
          find "${ADM_LOGS}" -maxdepth 1 -type f -name '*.log' -exec rm -f {} \; 2>/dev/null || true
        fi
      fi
    fi
  fi

  size_after=$(_du_bytes "${ADM_ROOT}")
  if [ "$size_before" -ge "$size_after" ]; then
    freed_total=$((size_before - size_after))
  else
    freed_total=0
  fi

  log_summary() {
    # local summary printed to terminal
    printf "\n─────────────────────────────────────────────\n"
    printf "Limpeza concluída (modo: %s)\n" "${CLEAN_MODE}"
    printf "─────────────────────────────────────────────\n"
    printf "Espaço antes: %s\n" "$(_bytes_to_human "$size_before")"
    printf "Espaço depois: %s\n" "$(_bytes_to_human "$size_after")"
    printf "Liberado: %s\n" "$(_bytes_to_human "$freed_total")"
    printf "Tempo: %s\n\n" "$(date -u -d "@$(( $(date +%s) - _LOG_START_TS 2>/dev/null || 0 ))" +%H:%M:%S 2>/dev/null || echo "00:00:00")"
  }

  # write detailed report in logs
  local report="${ADM_LOGS}/clean-$(date -u +%Y%m%dT%H%M%SZ).log"
  {
    printf "Clean mode: %s\n" "${CLEAN_MODE}"
    printf "Start: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf "Root: %s\n" "${ADM_ROOT}"
    printf "Freed: %s\n" "$(_bytes_to_human "$freed_total")"
    printf "End: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >> "${report}"

  ok "Clean finished. Freed: $(_bytes_to_human "$freed_total") (see ${report})"

  # release lock (trap will also release)
  release_lock
}

# run main with args
main "$@"
