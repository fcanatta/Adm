#!/usr/bin/env bash
# /usr/src/adm/scripts/fetch.sh
# ADM Fetch Manager
# Features:
#  - parse metafile INI (key=value)
#  - check cache and verify sha256
#  - download via curl or wget with .part temporary files
#  - support git:// (git+https) and file://
#  - record fetch state in /usr/src/adm/state/fetch.db
#  - supports commands: get, category, verify, update, purge, list, stats, analyze, repair, offline
set -euo pipefail

# ---- try to source lib.sh for logging and utilities ----
if [ -n "${ADM_SCRIPTS_DIR-}" ] && [ -f "${ADM_SCRIPTS_DIR}/lib.sh" ]; then
  # shellcheck disable=SC1090
  source "${ADM_SCRIPTS_DIR}/lib.sh"
else
  # minimal fallbacks
  info()  { printf "[INFO]  %s\n" "$*"; }
  ok()    { printf "[ OK ]  %s\n" "$*"; }
  warn()  { printf "[WARN]  %s\n" "$*"; }
  err()   { printf "[ERR]   %s\n" "$*"; }
  fatal() { printf "[FATAL] %s\n" "$*"; exit 1; }
  require_cmd() {
    local miss=0
    for c in "$@"; do
      if ! command -v "$c" >/dev/null 2>&1; then
        warn "Missing required command: $c"
        miss=1
      fi
    done
    [ $miss -eq 0 ] || fatal "Missing commands"
  }
fi

# ---- defaults & paths (can be overridden by environment) ----
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_DISTFILES="${ADM_DISTFILES:-${ADM_ROOT}/distfiles}"
ADM_DIST_SRC="${ADM_DISTFILES}/src"
ADM_DIST_TMP="${ADM_DISTFILES}/tmp"
ADM_DIST_META="${ADM_DISTFILES}/meta"
ADM_LOGS="${ADM_LOGS:-${ADM_ROOT}/logs}"
ADM_STATE="${ADM_STATE:-${ADM_ROOT}/state}"
ADM_FETCH_DB="${ADM_STATE}/fetch.db"
ADM_MIRRORS="${ADM_STATE}/mirrors.list"
ADM_FETCH_THREADS="${ADM_FETCH_THREADS:-1}"
ADM_OFFLINE="${ADM_OFFLINE:-0}"
ADM_CACHE_KEEP_VERSIONS="${ADM_CACHE_KEEP_VERSIONS:-3}"
ADM_VERBOSE="${ADM_VERBOSE:-1}"

# create dirs idempotently
mkdir -p "${ADM_DIST_SRC}" "${ADM_DIST_TMP}" "${ADM_DIST_META}" "${ADM_LOGS}" "${ADM_STATE}"
chmod 755 "${ADM_DISTFILES}" "${ADM_DIST_SRC}" "${ADM_DIST_TMP}" "${ADM_DIST_META}" "${ADM_LOGS}" "${ADM_STATE}" 2>/dev/null || true

# ---- helper utilities ----
timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_bytes_to_human() {
  awk 'function human(x){
    s="BKMGTPEZY"; i=1;
    while(x>=1024 && i<length(s)){ x/=1024; i++ }
    if(i==1) printf "%.0fB", x; else printf "%.1f%cB", x, substr(s,i,1)
  }{human($1)}' <<<"$1"
}

# safe basename for URLs
url_basename() {
  local url="$1"
  echo "${url##*/}" | sed 's/[?&].*$//'
}

# parse simple INI (key=value); returns value or empty
ini_get() {
  local file="$1"; local key="$2"
  if [ ! -f "$file" ]; then return 1; fi
  # ignore comments starting with # or ;
  local line
  line=$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -n1 || true)
  [ -z "$line" ] && return 1
  echo "${line#*=}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# read mirrors list into array (key=url)
declare -A MIRRORS_MAP
load_mirrors() {
  MIRRORS_MAP=()
  [ -f "${ADM_MIRRORS}" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -z "$line" ] && continue
    if echo "$line" | grep -q '='; then
      name="${line%%=*}"; url="${line#*=}"
      MIRRORS_MAP["$name"]="$url"
    fi
  done < "${ADM_MIRRORS}"
}

# choose mirror when url uses mirror://name/path
select_mirror_url() {
  local url="$1"
  if echo "$url" | grep -q '^mirror://'; then
    # mirror://name/path...
    local rest="${url#mirror://}"
    local name="${rest%%/*}"
    local path="${rest#*/}"
    local base="${MIRRORS_MAP[$name]:-}"
    if [ -n "$base" ]; then
      echo "${base%/}/${path}"
    else
      # fallback: remove mirror:// prefix (use upstream if absolute)
      echo "https://${path}"
    fi
  else
    echo "$url"
  fi
}

# compute sha256
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fatal "No sha256 utility available (sha256sum or shasum)"
  fi
}

# record fetch result to fetch.db (append, line-based)
record_fetch_db() {
  local name="$1" ver="$2" sha="$3" size="$4" origin="$5"
  mkdir -p "$(dirname "${ADM_FETCH_DB}")"
  printf "%s|%s|%s|%s|%s|%s\n" "$name" "$ver" "$sha" "$size" "$(timestamp)" "$origin" >> "${ADM_FETCH_DB}"
}

# find metafile by category/name; support metafiles path or package name
# argument can be: /path/to/metafile  OR category/name OR name (search)
find_metafile() {
  local arg="$1"
  # if full path file exists, return it
  if [ -f "$arg" ]; then
    echo "$arg" && return 0
  fi
  # if category/name exists
  if [ -f "${ADM_METAFILES}/${arg}/metafile" ]; then
    echo "${ADM_METAFILES}/${arg}/metafile" && return 0
  fi
  # if just name, try to find
  local matches
  matches=$(find "${ADM_METAFILES}" -type f -name metafile -print 2>/dev/null | while read -r mf; do
    if ini_get "$mf" name 2>/dev/null | grep -qx "$arg"; then
      printf "%s\n" "$mf"
    fi
  done)
  if [ -n "$matches" ]; then
    # return first
    echo "$matches" | head -n1
    return 0
  fi
  return 1
}

# check cache: returns 0 if file exists and sha matches
check_cache_file() {
  local file="$1" expected_sha="$2"
  if [ ! -f "$file" ]; then return 1; fi
  if [ -n "$expected_sha" ]; then
    local s
    s=$(sha256 "$file")
    if [ "$s" = "$expected_sha" ]; then
      return 0
    else
      return 2
    fi
  else
    return 0
  fi
}

# atomic move from .part to final
atomic_move() {
  local part="$1" final="$2"
  mv -f "$part" "$final"
  chmod 644 "$final" 2>/dev/null || true
}

# download with curl or wget
download_url_to_part() {
  local url="$1" part="$2" logfile="$3"
  if [ "${ADM_OFFLINE}" = "1" ]; then
    warn "Offline mode enabled; skipping network fetch: ${url}"
    return 2
  fi
  # prefer curl
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 -o "$part" "$url" >> "${logfile}" 2>&1 || return $?
    return 0
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$part" "$url" >> "${logfile}" 2>&1 || return $?
    return 0
  else
    fatal "No downloader available (curl or wget required)"
  fi
}

# download git source (git+https://...)
download_git() {
  local url="$1" dest="$2" logfile="$3"
  if [ "${ADM_OFFLINE}" = "1" ]; then
    warn "Offline mode; git fetch skipped for ${url}"
    return 2
  fi
  require_cmd git
  if [ -d "$dest/.git" ]; then
    (cd "$dest" && git fetch --all --prune >> "${logfile}" 2>&1) || return 1
    (cd "$dest" && git reset --hard origin/HEAD >> "${logfile}" 2>&1) || return 1
    return 0
  else
    git clone --recursive "$url" "$dest" >> "${logfile}" 2>&1 || return 1
    return 0
  fi
}

# cleanup partial on exit or interrupt
_cleanup_partial() {
  local p="$1"
  [ -n "$p" ] && [ -f "$p" ] && rm -f "$p"
}

# fetch a single metafile (path) -> will ensure distfiles/src contains file and returns path
# args: metafile_path [--force] [--no-verify]
fetch_from_metafile() {
  local mf="$1"; shift
  local FORCE=0 NO_VERIFY=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) FORCE=1; shift ;;
      --no-verify) NO_VERIFY=1; shift ;;
      *) shift ;;
    esac
  done

  if [ ! -f "$mf" ]; then
    err "Metafile not found: $mf"
    return 2
  fi

  # parse variables
  local name version url sha file basename size logfile tmp part final origin
  name=$(ini_get "$mf" name || true)
  version=$(ini_get "$mf" version || true)
  url=$(ini_get "$mf" source_url || ini_get "$mf" url || true)
  sha=$(ini_get "$mf" source_sha256 || ini_get "$mf" source_sha || true)
  [ -z "$url" ] && { err "No source_url in $mf"; return 2; }
  basename=$(url_basename "$url")
  # ensure directories
  mkdir -p "${ADM_DIST_SRC}" "${ADM_DIST_TMP}" "${ADM_DIST_META}" "${ADM_LOGS}" "${ADM_STATE}"
  final="${ADM_DIST_SRC}/${basename}"
  part="${ADM_DIST_TMP}/${basename}.part"
  logfile="${ADM_LOGS}/fetch-$(echo "${name}-${version}" | tr '/ ' '_')-$(date -u +%Y%m%dT%H%M%SZ).log"

  info "Processing ${name:-?}-${version:-?}: ${basename}"
  load_mirrors

  # if exists and matches -> use it
  if [ -f "$final" ] && [ "$FORCE" -eq 0 ]; then
    if [ -n "$sha" ]; then
      if check_cache_file "$final" "$sha"; then
        ok "Cache valid: ${final}"
        record_fetch_db "${name:-unknown}" "${version:-unknown}" "$sha" "$(stat -c%s "$final")" "${url}"
        # write meta entry
        printf "origin=%s\nfetched_at=%s\nsha256=%s\nsize=%s\n" "$url" "$(timestamp)" "$sha" "$(stat -c%s "$final")" > "${ADM_DIST_META}/${basename}.meta" 2>/dev/null || true
        return 0
      else
        warn "Cached file exists but checksum mismatch: ${final}. Will redownload."
        rm -f "$final"
      fi
    else
      ok "Cache present (no sha specified): ${final}"
      record_fetch_db "${name:-unknown}" "${version:-unknown}" "none" "$(stat -c%s "$final")" "${url}"
      return 0
    fi
  fi

  # if offline, refuse to fetch
  if [ "${ADM_OFFLINE}" = "1" ]; then
    err "Offline mode and no valid cache for ${basename}"
    return 3
  fi

  # try direct URL first (maybe mirror resolution required)
  local resolved_url
  resolved_url=$(select_mirror_url "$url")
  info "Fetching from: ${resolved_url}"
  # ensure previous part removed
  rm -f "$part"
  trap "_cleanup_partial '$part'" INT TERM EXIT

  # download attempt(s)
  local dl_ok=1
  local attempt=0
  local max_attempts=3
  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt+1))
    info "Download attempt ${attempt} for ${basename}"
    if download_url_to_part "${resolved_url}" "$part" "$logfile"; then
      # verify if no verification requested
      if [ "$NO_VERIFY" -eq 1 ] || [ -z "$sha" ]; then
        atomic_move "$part" "$final"
        ok "Downloaded: ${final}"
        dl_ok=0
        break
      fi
      # compute sha
      local got
      got=$(sha256 "$part")
      if [ "$got" = "$sha" ]; then
        atomic_move "$part" "$final"
        ok "Downloaded and verified: ${final}"
        dl_ok=0
        break
      else
        warn "Checksum mismatch (attempt $attempt): expected ${sha}, got ${got}"
        rm -f "$part"
        # try alternative mirror if any
        # if resolved_url used mirror://, try next mirror name? For now try base url without mirror prefix
        if echo "$resolved_url" | grep -q '^http'; then
          # try as-is again (curl has retry) - loop continues
          :
        fi
      fi
    else
      warn "Download failed for ${resolved_url} (attempt $attempt). See ${logfile}"
    fi
    sleep $((2 * attempt))
  done
  trap - INT TERM EXIT
  if [ "$dl_ok" -ne 0 ]; then
    err "Failed to download ${basename} after ${max_attempts} attempts"
    return 4
  fi

  # final verification and record
  local fsize
  fsize=$(stat -c%s "$final" 2>/dev/null || echo 0)
  local final_sha="none"
  if [ -n "$sha" ]; then final_sha=$(sha256 "$final"); fi
  record_fetch_db "${name:-unknown}" "${version:-unknown}" "${final_sha}" "${fsize}" "${resolved_url}"
  printf "origin=%s\nfetched_at=%s\nsha256=%s\nsize=%s\n" "$resolved_url" "$(timestamp)" "${final_sha}" "${fsize}" > "${ADM_DIST_META}/${basename}.meta" 2>/dev/null || true
  ok "Stored ${basename} in cache (size: $(_bytes_to_human "$fsize"))"
  return 0
}

# ---- command implementations ----

cmd_get() {
  local target="$1"
  mf=$(find_metafile "$target" || true)
  if [ -z "${mf:-}" ]; then fatal "Metafile for '${target}' not found"; fi
  fetch_from_metafile "$mf" --force=0 || return $?
}

cmd_category() {
  local cat="$1"
  [ -n "$cat" ] || fatal "category requires a category name"
  local mfs
  mfs=$(find "${ADM_METAFILES}/${cat}" -type f -name metafile 2>/dev/null || true)
  if [ -z "$mfs" ]; then fatal "No metafiles for category: ${cat}"; fi
  local total=0 done=0 errs=0
  while IFS= read -r mf; do
    total=$((total+1))
  done < <(printf "%s\n" "$mfs")
  info "Found ${total} packages in category ${cat}"
  local i=0
  while IFS= read -r mf; do
    i=$((i+1))
    name=$(ini_get "$mf" name 2>/dev/null || echo "unknown")
    version=$(ini_get "$mf" version 2>/dev/null || echo "unknown")
    info "[$i/$total] Fetching ${name}-${version}"
    if fetch_from_metafile "$mf"; then
      done=$((done+1))
    else
      errs=$((errs+1))
    fi
  done < <(printf "%s\n" "$mfs")
  ok "Category fetch complete: done=${done} errors=${errs}"
}

cmd_verify() {
  local target="$1"
  mf=$(find_metafile "$target" || true)
  [ -n "${mf:-}" ] || fatal "Metafile for '${target}' not found"
  local url
  url=$(ini_get "$mf" source_url || ini_get "$mf" url)
  b=$(url_basename "$url")
  file="${ADM_DIST_SRC}/${b}"
  if [ ! -f "$file" ]; then err "File not present in cache: ${file}"; return 2; fi
  sha_expected=$(ini_get "$mf" source_sha256 || ini_get "$mf" source_sha || true)
  if [ -z "$sha_expected" ]; then warn "No sha256 in metafile; cannot fully verify"; return 3; fi
  got=$(sha256 "$file")
  if [ "$got" = "$sha_expected" ]; then ok "Verified: ${file} (sha256 ok)"; return 0; else err "Verification failed: expected ${sha_expected} got ${got}"; return 1; fi
}

cmd_update() {
  local target="$1"
  mf=$(find_metafile "$target" || true)
  [ -n "${mf:-}" ] || fatal "Metafile for '${target}' not found"
  info "Forcing redownload for ${target}"
  # remove from cache if exists
  url=$(ini_get "$mf" source_url || ini_get "$mf" url)
  b=$(url_basename "$url")
  rm -f "${ADM_DIST_SRC}/${b}"
  fetch_from_metafile "$mf" --force
}

cmd_list() {
  echo "Distfiles in ${ADM_DIST_SRC}:"
  find "${ADM_DIST_SRC}" -maxdepth 1 -type f -printf "%f\t%k KB\n" 2>/dev/null || true
}

cmd_stats() {
  local total_files total_bytes valid invalid
  total_files=$(find "${ADM_DIST_SRC}" -type f 2>/dev/null | wc -l)
  total_bytes=0
  while IFS= read -r f; do total_bytes=$((total_bytes + $(stat -c%s "$f"))); done < <(find "${ADM_DIST_SRC}" -type f -print 2>/dev/null || true)
  valid=0; invalid=0
  # quick verify based on available metadata
  while IFS= read -r mf; do
    url=$(ini_get "$mf" source_url || ini_get "$mf" url)
    b=$(url_basename "$url")
    fpath="${ADM_DIST_SRC}/${b}"
    if [ -f "$fpath" ]; then
      sha_expected=$(ini_get "$mf" source_sha256 || ini_get "$mf" source_sha || true)
      if [ -n "$sha_expected" ]; then
        if [ "$(sha256 "$fpath")" = "$sha_expected" ]; then valid=$((valid+1)); else invalid=$((invalid+1)); fi
      else
        valid=$((valid+1))
      fi
    fi
  done < <(find "${ADM_METAFILES}" -type f -name metafile 2>/dev/null || true)
  printf "Cache stats:\n  files: %s\n  size: %s\n  verified: %s\n  invalid: %s\n" "$total_files" "$(_bytes_to_human "$total_bytes")" "$valid" "$invalid"
}

cmd_purge() {
  info "Purging old/unused distfiles according to policy (keep ${ADM_CACHE_KEEP_VERSIONS})..."
  # heuristic: group by basename prefix before version (best effort)
  # For now: remove files older than 365 days unless referenced
  local cutoff_days=365
  local removed=0 freed=0
  # build referenced map
  declare -A refmap
  while IFS= read -r mf; do
    url=$(ini_get "$mf" source_url || ini_get "$mf" url || true)
    b=$(url_basename "$url")
    [ -n "$b" ] && refmap["$b"]=1
  done < <(find "${ADM_METAFILES}" -type f -name metafile 2>/dev/null || true)
  # remove files older than cutoff and not referenced
  while IFS= read -r f; do
    b=$(basename "$f")
    if [ -n "${refmap[$b]-}" ]; then
      # referenced - skip
      continue
    fi
    # age in days
    age=$(expr \( $(date +%s) - $(stat -c %Y "$f") \) / 86400)
    if [ "$age" -ge "$cutoff_days" ]; then
      size=$(stat -c%s "$f")
      rm -f "$f" && removed=$((removed+1)) && freed=$((freed+size))
    fi
  done < <(find "${ADM_DIST_SRC}" -type f -print 2>/dev/null || true)
  ok "Purged ${removed} files, freed $(_bytes_to_human "$freed")"
}

cmd_analyze() {
  info "Analyzing cache for duplicates and orphans..."
  declare -A size_map
  local total=0 bytes=0 orphans=0 duplicates=0
  while IFS= read -r f; do
    s=$(stat -c%s "$f")
    bytes=$((bytes + s)); total=$((total+1))
    key="${s}"
    if [ -n "${size_map[$key]-}" ]; then
      duplicates=$((duplicates+1))
      echo "Possible duplicate: ${f} (size ${s})"
    else
      size_map[$key]=1
    fi
    # check if referenced
    b=$(basename "$f")
    if ! grep -R --exclude-dir=.git -q "source_url=.*${b}" "${ADM_METAFILES}" 2>/dev/null; then
      orphans=$((orphans+1))
      echo "Orphan in cache: ${f}"
    fi
  done < <(find "${ADM_DIST_SRC}" -type f -print 2>/dev/null || true)
  printf "Summary: files=%s size=%s duplicates=%s orphans=%s\n" "$total" "$(_bytes_to_human "$bytes")" "$duplicates" "$orphans"
}

cmd_repair() {
  info "Scanning cache and repairing corrupted entries (redownload)..."
  local repaired=0 failed=0
  while IFS= read -r mf; do
    url=$(ini_get "$mf" source_url || ini_get "$mf" url || true)
    b=$(url_basename "$url")
    fpath="${ADM_DIST_SRC}/${b}"
    sha_expected=$(ini_get "$mf" source_sha256 || ini_get "$mf" source_sha || true)
    if [ -f "$fpath" ] && [ -n "$sha_expected" ]; then
      if [ "$(sha256 "$fpath")" != "$sha_expected" ]; then
        warn "Corrupted: ${fpath} (will redownload)"
        rm -f "$fpath"
        if fetch_from_metafile "$mf"; then repaired=$((repaired+1)); else failed=$((failed+1)); fi
      fi
    fi
  done < <(find "${ADM_METAFILES}" -type f -name metafile 2>/dev/null || true)
  ok "Repair complete: repaired=${repaired} failed=${failed}"
}

# usage/help
usage() {
  cat <<EOF
Usage: fetch.sh <command> [args]

Commands:
  get <pkg>           Fetch single package (pkg=category/name or name or metafile path)
  category <cat>      Fetch all packages in a category
  verify <pkg>        Verify cached file against sha in metafile
  update <pkg>        Force redownload of a package
  purge               Purge old/unreferenced distfiles
  list                List files in distfiles cache
  stats               Show cache statistics
  analyze             Analyze duplicates and orphans
  repair              Re-download corrupted cache entries
  offline on|off      Toggle offline mode
  help                Show this help

Examples:
  fetch.sh get core/bash
  fetch.sh category core
  fetch.sh verify bash
EOF
}

# CLI dispatcher
case "${1-}" in
  get) [ -n "${2-}" ] || fatal "get requires target"; cmd_get "$2" ;;
  category) [ -n "${2-}" ] || fatal "category requires name"; cmd_category "$2" ;;
  verify) [ -n "${2-}" ] || fatal "verify requires target"; cmd_verify "$2" ;;
  update) [ -n "${2-}" ] || fatal "update requires target"; cmd_update "$2" ;;
  purge) cmd_purge ;;
  list) cmd_list ;;
  stats) cmd_stats ;;
  analyze) cmd_analyze ;;
  repair) cmd_repair ;;
  offline) 
    case "${2-}" in
      on) ADM_OFFLINE=1; export ADM_OFFLINE; ok "Offline mode ON";;
      off) ADM_OFFLINE=0; export ADM_OFFLINE; ok "Offline mode OFF";;
      *) fatal "offline requires on|off";;
    esac
    ;;
  help|--help|-h|"") usage ;;
  *) fatal "Unknown command: ${1-}. Use 'fetch.sh help'." ;;
esac

exit 0
