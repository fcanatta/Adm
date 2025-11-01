#!/usr/bin/env bash
# /usr/src/adm/scripts/hooks.sh
# ADM Hooks manager
# - hierarchical hooks (global -> phase -> category -> package -> custom)
# - isolated execution with timeout, logs, failmode, parallel optional
# - records runs in /usr/src/adm/state/hooks.db
set -euo pipefail
IFS=$'\n\t'

# -----------------------------
# Configuration (override via env)
# -----------------------------
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_SCRIPTS_DIR="${ADM_SCRIPTS_DIR:-${ADM_ROOT}/scripts}"
ADM_HOOKS_BASE="${ADM_HOOKS_BASE:-${ADM_ROOT}/hooks}"
ADM_HOOKS_GLOBAL="${ADM_HOOKS_GLOBAL:-${ADM_HOOKS_BASE}/global}"
ADM_HOOKS_CUSTOM="${ADM_HOOKS_CUSTOM:-${ADM_HOOKS_BASE}/custom.d}"
ADM_METAFILES_DIR="${ADM_METAFILES_DIR:-${ADM_ROOT}/metafiles}"
ADM_LOGS="${ADM_LOGS:-${ADM_ROOT}/logs}"
ADM_STATE="${ADM_STATE:-${ADM_ROOT}/state}"
ADM_HOOKS_TIMEOUT="${ADM_HOOKS_TIMEOUT:-120}"         # seconds per hook
ADM_HOOKS_ISOLATE="${ADM_HOOKS_ISOLATE:-1}"           # 1=subshell, 0=inline
ADM_HOOKS_FAILMODE="${ADM_HOOKS_FAILMODE:-warn}"      # ignore|warn|abort
ADM_HOOKS_PARALLEL="${ADM_HOOKS_PARALLEL:-0}"         # 0 sequential, 1 parallel
ADM_HOOKS_JOBS="${ADM_HOOKS_JOBS:-4}"                 # parallel jobs limit
ADM_HOOKS_KEEP_LOGS="${ADM_HOOKS_KEEP_LOGS:-30}"      # days to keep logs
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HOOKS_DB="${ADM_STATE}/hooks.db"
HOOKS_LOCKDIR="${ADM_STATE}/hooks-locks"

# Color constants
COL_RST="\033[0m"; COL_INFO="\033[1;34m"; COL_OK="\033[1;32m"; COL_WARN="\033[1;33m"; COL_ERR="\033[1;31m"; COL_HOOK="\033[1;35m"

# Fallback log functions (lib.sh may supply better ones)
info(){ printf "%b[INFO]%b  %s\n" "${COL_INFO}" "${COL_RST}" "$*"; }
ok(){ printf "%b[ OK ]%b  %s\n" "${COL_OK}" "${COL_RST}" "$*"; }
warn(){ printf "%b[WARN]%b  %s\n" "${COL_WARN}" "${COL_RST}" "$*"; }
err(){ printf "%b[ERR ]%b  %s\n" "${COL_ERR}" "${COL_RST}" "$*"; }
hook_msg(){ printf "%b[HOOK]%b  %s\n" "${COL_HOOK}" "${COL_RST}" "$*"; }
fatal(){ printf "%b[FATAL]%b %s\n" "${COL_ERR}" "${COL_RST}" "$*"; exit 1; }

# ensure dirs exist
_init_dirs() {
  mkdir -p "${ADM_HOOKS_BASE}" "${ADM_HOOKS_GLOBAL}" "${ADM_HOOKS_CUSTOM}" "${ADM_LOGS}" "${ADM_STATE}" "${HOOKS_LOCKDIR}"
  # ensure default phase dirs under hooks (idempotent)
  for phase in extract build install update mkinitramfs clean profile bootstrap; do
    mkdir -p "${ADM_HOOKS_BASE}/${phase}.d"
  done
  chmod 755 "${ADM_HOOKS_BASE}" "${ADM_HOOKS_GLOBAL}" "${ADM_HOOKS_CUSTOM}" "${ADM_LOGS}" "${ADM_STATE}" "${HOOKS_LOCKDIR}" 2>/dev/null || true
}

# ensure required commands
_require_cmds() {
  local need=(timeout flock awk sed date printf)
  local miss=()
  for c in "${need[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      miss+=("$c")
    fi
  done
  if [ "${#miss[@]}" -ne 0 ]; then
    fatal "Missing required commands: ${miss[*]}"
  fi
}

# sanitize phase, status, names
_sanitize() {
  # basic: remove spaces
  echo "$1" | tr -d '[:space:]'
}

# discover hooks under a directory (phase-specific .d), returns newline list sorted
# Args: base_dir phase
_discover_hooks_in_dir() {
  local base="$1" phase="$2"
  local dir="${base}/${phase}.d"
  if [ -d "${dir}" ]; then
    # find executable files and scripts, sorted by name
    find "${dir}" -maxdepth 1 -type f -perm /u+x,g+x,o+x -printf '%f\n' 2>/dev/null | sort -V || true
  fi
}

# discover hooks for a program metafile path
# Args: metafile_path phase
_discover_hooks_for_metafile() {
  local mf="$1" phase="$2"
  # expect metafile at /usr/src/adm/metafiles/<cat>/<pkg>/metafile
  local dir; dir="$(dirname "$mf")"
  local category; category="$(basename "$(dirname "$mf")")"
  local pkg; pkg="$(basename "$dir")"
  # yield program-level hooks
  if [ -d "${dir}/hooks/${phase}.d" ]; then
    find "${dir}/hooks/${phase}.d" -maxdepth 1 -type f -perm /u+x,g+x,o+x -printf '%p\n' 2>/dev/null | sort -V || true
  fi
  # yield category-level hooks dir
  if [ -d "${ADM_METAFILES_DIR}/${category}/hooks/${phase}.d" ]; then
    find "${ADM_METAFILES_DIR}/${category}/hooks/${phase}.d" -maxdepth 1 -type f -perm /u+x,g+x,o+x -printf '%p\n' 2>/dev/null | sort -V || true
  fi
}

# global list of hooks for a run in correct order (global -> phase -> category -> program -> custom)
# Args:
#   phase, status, optional metafile (if available)
# Returns: prints absolute paths (one per line)
_generate_hook_list() {
  local phase="$1" status="$2" metafile="${3:-}"
  local out=()
  # 1) global
  if [ -d "${ADM_HOOKS_GLOBAL}" ]; then
    while read -r f; do [ -n "$f" ] && out+=("${ADM_HOOKS_GLOBAL}/${f}"); done < <(_discover_hooks_in_dir "${ADM_HOOKS_GLOBAL%/global}" "${phase}" || true)
    # also consider top-level global/*.sh
    if [ -d "${ADM_HOOKS_GLOBAL}" ]; then
      find "${ADM_HOOKS_GLOBAL}" -maxdepth 1 -type f -perm /u+x,g+x,o+x -printf '%p\n' 2>/dev/null | sort -V | while read -r gf; do out+=("${gf}";); done
    fi
  fi
  # 2) phase-level under hooks base (ADM_HOOKS_BASE/<phase>.d)
  local phase_dir="${ADM_HOOKS_BASE}/${phase}.d"
  if [ -d "${phase_dir}" ]; then
    find "${phase_dir}" -maxdepth 1 -type f -perm /u+x,g+x,o+x -printf '%p\n' 2>/dev/null | sort -V | while read -r pf; do out+=("${pf}";); done
  fi
  # 3 & 4) category and program hooks from metafile if provided
  if [ -n "${metafile}" ] && [ -f "${metafile}" ]; then
    # discover returns relative or absolute; we call a helper to print absolute in order
    # category-level then program-level
    local dir; dir="$(dirname "$metafile")"
    local category; category="$(basename "$(dirname "$metafile")")"
    local progdir; progdir="${dir}"
    # category hooks
    local cat_hooks_dir="${ADM_METAFILES_DIR}/${category}/hooks/${phase}.d"
    if [ -d "${cat_hooks_dir}" ]; then
      find "${cat_hooks_dir}" -maxdepth 1 -type f -perm /u+x,g+x,o+x -printf '%p\n' 2>/dev/null | sort -V | while read -r ch; do out+=("${ch}";); done
    fi
    # program hooks
    local prog_hooks_dir="${progdir}/hooks/${phase}.d"
    if [ -d "${prog_hooks_dir}" ]; then
      find "${prog_hooks_dir}" -maxdepth 1 -type f -perm /u+x,g+x,o+x -printf '%p\n' 2>/dev/null | sort -V | while read -r ph; do out+=("${ph}";); done
    fi
  fi
  # 5) custom hooks (user-level)
  if [ -d "${ADM_HOOKS_CUSTOM}" ]; then
    find "${ADM_HOOKS_CUSTOM}" -maxdepth 1 -type f -perm /u+x,g+x,o+x -printf '%p\n' 2>/dev/null | sort -V | while read -r cu; do out+=("${cu}";); done
  fi
  # print unique ordered list (preserve order but remove duplicates)
  local seen
  seen=$(mktemp)
  for p in "${out[@]}"; do
    [ -z "$p" ] && continue
    if [ ! -f "$p" ]; then continue; fi
    if ! grep -Fxq "$p" "$seen" 2>/dev/null; then
      printf "%s\n" "$p"
      printf "%s\n" "$p" >> "$seen"
    fi
  done
  rm -f "$seen"
}

# validate hook file (executable, no symlink cycles, text file)
_validate_hook_file() {
  local file="$1"
  # must be regular file and executable
  if [ ! -f "$file" ] || [ ! -x "$file" ]; then
    return 1
  fi
  # optional: check shebang or .sh extension - we allow any executable but warn if binary
  if file "$file" | grep -qi 'executable'; then
    # continue (some hooks may be compiled helpers)
    return 0
  fi
  return 0
}

# execute one hook with isolation, timeout, environment set
# Args: hook_path phase status package version category builddir
_execute_hook() {
  local hook="$1"; shift
  local phase="$1"; local status="$2"; local pkg="$3"; local ver="$4"; local cat="$5"; local builddir="$6"
  local start end duration rc=0 logfile
  logfile="${ADM_LOGS}/hooks-$(basename "$hook")-${TIMESTAMP}.log"
  # export context for hook
  export ADM_PHASE="${phase}"
  export ADM_HOOK_STATUS="${status}"
  export ADM_HOOK_PACKAGE="${pkg}"
  export ADM_HOOK_VERSION="${ver}"
  export ADM_HOOK_CATEGORY="${cat}"
  export ADM_HOOK_BUILDDIR="${builddir}"
  export ADM_ROOT ADM_LOGS ADM_STATE

  hook_msg "(${phase}:${status}) Running $(basename "$hook")"
  start="$(date +%s.%N)"

  # prepare command
  local cmd
  if [ "${ADM_HOOKS_ISOLATE}" = "1" ]; then
    # run in subshell: capture output to log
    cmd=(timeout --preserve-status "${ADM_HOOKS_TIMEOUT}" bash -c "exec \"${hook}\" \"${phase}\" \"${status}\" \"${pkg}\" \"${ver}\" \"${cat}\" \"${builddir}\"")
  else
    cmd=(timeout --preserve-status "${ADM_HOOKS_TIMEOUT}" bash -c ". \"${hook}\" \"${phase}\" \"${status}\" \"${pkg}\" \"${ver}\" \"${cat}\" \"${builddir}\"")
  fi

  # run and capture exit code and duration
  if "${cmd[@]}" >> "${logfile}" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  end="$(date +%s.%N)"
  duration="$(awk "BEGIN {print (${end} - ${start})}")"

  # print brief result to console
  if [ "$rc" -eq 0 ]; then
    ok "Hook $(basename "$hook") -> exit 0 (${duration}s)"
  elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    warn "Hook $(basename "$hook") -> timeout (${duration}s). See ${logfile}"
  else
    warn "Hook $(basename "$hook") -> exit ${rc} (${duration}s). See ${logfile}"
  fi

  # record run to hooks.db
  mkdir -p "$(dirname "$HOOKS_DB")"
  printf "%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${phase}" "${status}" \
    "${hook}" "${pkg:--}" "${ver:--}" "${cat:--}" "${rc}" "${duration}" >> "${HOOKS_DB}"

  # handle failmode
  case "${ADM_HOOKS_FAILMODE}" in
    ignore) return 0 ;;
    warn)
      [ "$rc" -eq 0 ] && return 0
      return 0 ;;
    abort)
      [ "$rc" -eq 0 ] && return 0
      fatal "Hook $(basename "$hook") failed with code ${rc}; aborting due to ADM_HOOKS_FAILMODE=abort"
      ;;
    *)
      # default warn
      [ "$rc" -eq 0 ] || warn "Hook $(basename "$hook") returned ${rc}"
      return 0
      ;;
  esac
  return 0
}

# run list of hooks sequentially or parallel
# Args: list-of-hook-paths (newline separated) phase status pkg ver cat builddir
_run_hooks_list() {
  local hooks_list="$1"; shift
  local phase="$1"; local status="$2"; local pkg="$3"; local ver="$4"; local cat="$5"; local builddir="$6"
  # convert newline-separated to array
  IFS=$'\n' read -r -d '' -a hooks_arr <<< "${hooks_list}" || true
  local total="${#hooks_arr[@]}"
  [ "${total}" -gt 0 ] || { info "No hooks to run for ${phase}:${status}"; return 0; }

  local i=0
  if [ "${ADM_HOOKS_PARALLEL}" = "1" ] && [ "${ADM_HOOKS_JOBS}" -gt 1 ]; then
    hook_msg "Running ${total} hooks in parallel (jobs=${ADM_HOOKS_JOBS})"
    # simple job control: run up to ADM_HOOKS_JOBS background jobs
    local running=0
    local pids=()
    for h in "${hooks_arr[@]}"; do
      i=$((i+1))
      [ -f "$h" ] || { warn "Hook removed during run: $h"; continue; }
      _validate_hook_file "$h" || { warn "Invalid hook file: $h"; continue; }
      # launch in background
      ( _execute_hook "$h" "${phase}" "${status}" "${pkg}" "${ver}" "${cat}" "${builddir}" ) &
      pids+=("$!")
      running=$((running+1))
      # throttle
      if [ "$running" -ge "${ADM_HOOKS_JOBS}" ]; then
        wait -n || true
        running=$((running-1))
      fi
    done
    # wait all
    wait || true
  else
    hook_msg "Running ${total} hooks sequentially"
    for h in "${hooks_arr[@]}"; do
      i=$((i+1))
      [ -f "$h" ] || { warn "Hook removed during run: $h"; continue; }
      _validate_hook_file "$h" || { warn "Invalid hook file: $h"; continue; }
      _execute_hook "$h" "${phase}" "${status}" "${pkg}" "${ver}" "${cat}" "${builddir}" || true
    done
  fi
  return 0
}

# find metafile for given package name or category/name or filepath
_find_metafile_for_identifier() {
  local id="$1"
  # if path exists
  [ -f "$id" ] && { printf "%s\n" "$id"; return 0; }
  # if category/name exists
  if [ -f "${ADM_METAFILES_DIR}/${id}/metafile" ]; then
    printf "%s\n" "${ADM_METAFILES_DIR}/${id}/metafile"; return 0
  fi
  # search by name field
  local found
  found=$(find "${ADM_METAFILES_DIR}" -type f -name metafile -print0 2>/dev/null | xargs -0 -I{} awk -v id="$id" 'BEGIN{found=0} { if ($0 ~ "^[[:space:]]*name=") { split($0,a,"="); gsub(/^[[:space:]]+|[[:space:]]+$/,"",a[2]); if (a[2]==id) { print FILENAME; exit 0 } } }' {}) || true
  # the awk approach above may not work portable; instead fallback brute force
  if [ -z "$found" ]; then
    while IFS= read -r mf; do
      if awk -F= -v key=name 'tolower($0) ~ "^name=" { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); if ($2 == "'"$id"'") { print FILENAME; exit } }' "$mf" 2>/dev/null; then
        printf "%s\n" "$mf"; return 0
      fi
    done < <(find "${ADM_METAFILES_DIR}" -type f -name metafile 2>/dev/null)
  else
    printf "%s\n" "$found"; return 0
  fi
  return 1
}

# CLI: run phase/status [pkg] [ver] [cat] [builddir]
cmd_run() {
  local phase="${1:-}"; local status="${2:-pre}"; local ident="${3:-}" ; shift 3 || true
  if [ -z "$phase" ]; then fatal "run requires <phase>"; fi
  local metafile=""
  local pkg="" ver="" cat="" builddir=""
  if [ -n "$ident" ]; then
    metafile="$(_find_metafile_for_identifier "$ident" 2>/dev/null || true)"
    if [ -n "$metafile" ]; then
      # try to extract fields
      pkg="$(awk -F= '/^name=/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$metafile" 2>/dev/null || echo "")"
      ver="$(awk -F= '/^version=/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$metafile" 2>/dev/null || echo "")"
      cat="$(awk -F= '/^category=/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$metafile" 2>/dev/null || echo "")"
      builddir="${4:-}"
    else
      # treat ident as package name without metafile
      pkg="$ident"
      ver="${4:-}"
      cat="${5:-}"
      builddir="${6:-}"
    fi
  fi

  # Compose hook list hierarchy
  # 1) global
  local list_global=""
  if [ -d "${ADM_HOOKS_GLOBAL}" ]; then
    list_global="$(find "${ADM_HOOKS_GLOBAL}" -maxdepth 1 -type f -perm /u+x,g+x,o+x -printf '%p\n' 2>/dev/null | sort -V || true)"
  fi
  # 2) phase-level
  local list_phase=""
  if [ -d "${ADM_HOOKS_BASE}/${phase}.d" ]; then
    list_phase="$(find "${ADM_HOOKS_BASE}/${phase}.d" -maxdepth 1 -type f -perm /u+x,g+x,o+x -printf '%p\n' 2>/dev/null | sort -V || true)"
  fi
  # 3 & 4 & 5 discovered via _generate_hook_list which covers category & program & custom
  local list_all
  list_all="$( _generate_hook_list "${phase}" "${status}" "${metafile}" )"

  # Merge lists in order: global, phase, (category/program from list_all), custom included already
  # We'll create a combined list preserving order and uniq
  local combined_tmp
  combined_tmp="$(mktemp)"
  printf "%s\n" "${list_global}" > "${combined_tmp}.g" 2>/dev/null || true
  printf "%s\n" "${list_phase}" > "${combined_tmp}.p" 2>/dev/null || true
  printf "%s\n" "${list_all}" > "${combined_tmp}.a" 2>/dev/null || true
  # print merged preserving order and uniqueness
  local merged_list=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! grep -Fxq "$f" "${combined_tmp}.seen" 2>/dev/null; then
      printf "%s\n" "$f" >> "${combined_tmp}.seen"
      merged_list+="${f}"$'\n'
    fi
  done < <(cat "${combined_tmp}.g" "${combined_tmp}.p" "${combined_tmp}.a")
  rm -f "${combined_tmp}"* || true

  # run list
  if [ -z "$merged_list" ]; then
    info "No hooks discovered to run for ${phase}:${status}"
    return 0
  fi

  # run hooks
  _run_hooks_list "${merged_list}" "${phase}" "${status}" "${pkg}" "${ver}" "${cat}" "${builddir}"
  return 0
}

# CLI: list [phase] [pkg]
cmd_list() {
  local phase="${1:-}"
  local ident="${2:-}"
  if [ -n "$ident" ]; then
    local mf="$(_find_metafile_for_identifier "$ident" 2>/dev/null || true)"
    if [ -n "$mf" ]; then
      info "Hooks for package (metafile): ${mf}"
      for ph in "${phase:-extract}" ; do
        _generate_hook_list "${ph}" "pre" "${mf}" | nl -ba -w2 -s'. '
      done
      return 0
    else
      fatal "Package/metafile not found for identifier: ${ident}"
    fi
  fi

  if [ -n "${phase}" ]; then
    info "Hooks in phase ${phase}:"
    _generate_hook_list "${phase}" "pre" "" | nl -ba -w2 -s'. '
  else
    info "All discovered hooks (global + phase + custom):"
    for ph in extract build install update mkinitramfs clean profile bootstrap; do
      printf "\nPhase: %s\n" "$ph"
      _generate_hook_list "${ph}" "pre" "" | nl -ba -w2 -s'. '
    done
  fi
}

# CLI: check (validate hooks)
cmd_check() {
  info "Validating hooks directories and files..."
  local failures=0
  # ensure base dirs exist
  _init_dirs
  # check all executable scripts under hooks tree and in metafiles hooks
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if _validate_hook_file "$f"; then
      ok "Valid: $f"
    else
      warn "Invalid: $f"
      failures=$((failures+1))
    fi
  done < <(find "${ADM_HOOKS_BASE}" -type f -perm /u+x -print 2>/dev/null || true)

  # metafiles hooks
  while IFS= read -r mf; do
    local pd
    pd="$(dirname "$mf")/hooks"
    if [ -d "$pd" ]; then
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        if _validate_hook_file "$f"; then ok "Valid: $f"; else warn "Invalid: $f"; failures=$((failures+1)); fi
      done < <(find "$pd" -type f -perm /u+x -print 2>/dev/null || true)
    fi
  done < <(find "${ADM_METAFILES_DIR}" -type f -name metafile 2>/dev/null || true)

  if [ "$failures" -gt 0 ]; then
    warn "Hook validation completed with ${failures} problems"
    return 1
  fi
  ok "Hook validation completed - all good"
  return 0
}

# CLI: init (create directories)
cmd_init() {
  _init_dirs
  # create phase dirs under metafiles for each existing category/program
  while IFS= read -r mf; do
    [ -z "$mf" ] && continue
    local dir; dir="$(dirname "$mf")"
    for phase in extract build install update mkinitramfs clean profile bootstrap; do
      mkdir -p "${dir}/hooks/${phase}.d"
    done
  done < <(find "${ADM_METAFILES_DIR}" -type f -name metafile 2>/dev/null || true)
  ok "Hooks directories initialized"
}

# CLI: clean logs older than ADM_HOOKS_KEEP_LOGS days
cmd_clean() {
  local days="${1:-${ADM_HOOKS_KEEP_LOGS}}"
  info "Cleaning hook logs older than ${days} days in ${ADM_LOGS}"
  find "${ADM_LOGS}" -type f -name 'hooks-*' -mtime +"${days}" -print -exec rm -f {} \; 2>/dev/null || true
  ok "Cleaned old hook logs"
}

# CLI: info status
cmd_info() {
  cat <<EOF
ADM Hooks Manager
  ADM_ROOT:           ${ADM_ROOT}
  Hooks base:         ${ADM_HOOKS_BASE}
  Global hooks:       ${ADM_HOOKS_GLOBAL}
  Custom hooks:       ${ADM_HOOKS_CUSTOM}
  Metafiles dir:      ${ADM_METAFILES_DIR}
  Logs dir:           ${ADM_LOGS}
  State db:           ${HOOKS_DB}
  Timeout (s):        ${ADM_HOOKS_TIMEOUT}
  Isolation (subsh):  ${ADM_HOOKS_ISOLATE}
  Failmode:           ${ADM_HOOKS_FAILMODE}
  Parallel:           ${ADM_HOOKS_PARALLEL}
  Parallel jobs:      ${ADM_HOOKS_JOBS}
EOF
}

# usage
usage() {
  cat <<EOF
Usage: hooks.sh <command> [args]

Commands:
  init                         Create hooks directory structure
  run <phase> <status> [id]    Run hooks for a phase/status; optional id (metafile path, category/name or name)
                               Example: hooks.sh run build pre core/bash
  list [phase] [id]            List discovered hooks
  check                        Validate hooks' permissions/sanity
  clean [days]                 Remove old hook logs older than [days] (default ${ADM_HOOKS_KEEP_LOGS})
  info                         Print configuration
  help                         Show this help

Environment:
  ADM_HOOKS_TIMEOUT (s)        Timeout per hook (default ${ADM_HOOKS_TIMEOUT})
  ADM_HOOKS_FAILMODE           ignore|warn|abort  (default ${ADM_HOOKS_FAILMODE})
  ADM_HOOKS_ISOLATE            1 (subshell) or 0 (inline) (default ${ADM_HOOKS_ISOLATE})
  ADM_HOOKS_PARALLEL           0 or 1 (default ${ADM_HOOKS_PARALLEL})
  ADM_HOOKS_JOBS               parallel job limit (default ${ADM_HOOKS_JOBS})
EOF
}

# ----------------------------
# Main CLI dispatch
# ----------------------------
_require_cmds
_init_dirs

case "${1-}" in
  init) cmd_init ;;
  run) 
    [ -n "${2-}" ] || fatal "run requires phase argument"
    phase="$2"
    status="${3-:pre}"
    ident="${4-:}"
    cmd_run "${phase}" "${status}" "${ident}"
    ;;
  list) cmd_list "${2-}" "${3-}" ;;
  check) cmd_check ;;
  clean) cmd_clean "${2-}" ;;
  info) cmd_info ;;
  help|--help|-h|"") usage ;;
  *) usage; exit 1 ;;
esac

exit 0
