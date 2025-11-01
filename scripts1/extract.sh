#!/usr/bin/env bash
# /usr/src/adm/scripts/extract.sh
# ADM Extract Utility - intelligent, idempotent, automatic patches
# Usage: extract.sh <metafile|category/name|name> | --category <cat> | --all | --verify <metafile|name>
set -euo pipefail
IFS=$'\n\t'

# ---- try to source lib.sh for logging and helpers ----
if [ -n "${ADM_SCRIPTS_DIR-}" ] && [ -f "${ADM_SCRIPTS_DIR}/lib.sh" ]; then
  # shellcheck disable=SC1090
  source "${ADM_SCRIPTS_DIR}/lib.sh"
else
  # Fallback logging
  COL_RESET="\033[0m"; COL_INFO="\033[1;34m"; COL_OK="\033[1;32m"; COL_WARN="\033[1;33m"; COL_ERR="\033[1;31m"
  info(){ printf "%b[INFO]%b  %s\n" "${COL_INFO}" "${COL_RESET}" "$*"; }
  ok(){ printf "%b[ OK ]%b  %s\n" "${COL_OK}" "${COL_RESET}" "$*"; }
  warn(){ printf "%b[WARN]%b  %s\n" "${COL_WARN}" "${COL_RESET}" "$*"; }
  err(){ printf "%b[ERR ]%b  %s\n" "${COL_ERR}" "${COL_RESET}" "$*"; }
  fatal(){ printf "%b[FATAL]%b %s\n" "${COL_ERR}" "${COL_RESET}" "$*"; exit 1; }
fi

# ---- configuration (overridable by environment) ----
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_SCRIPTS_DIR="${ADM_SCRIPTS_DIR:-${ADM_ROOT}/scripts}"
ADM_DIST_SRC="${ADM_DIST_SRC:-${ADM_ROOT}/distfiles/src}"
ADM_BUILD_BASE="${ADM_BUILD_BASE:-${ADM_ROOT}/build}"
ADM_PATCHES_DIR="${ADM_PATCHES_DIR:-${ADM_ROOT}/patches}"
ADM_HOOKS_DIR="${ADM_HOOKS_DIR:-${ADM_ROOT}/hooks/extract.d}"
ADM_LOGS="${ADM_LOGS:-${ADM_ROOT}/logs}"
ADM_STATE="${ADM_STATE:-${ADM_ROOT}/state}"
ADM_OFFLINE="${ADM_OFFLINE:-0}"
ADM_CLEAN_OLD_BUILDS="${ADM_CLEAN_OLD_BUILDS:-1}"
ADM_PARALLEL_EXTRACT="${ADM_PARALLEL_EXTRACT:-0}"
ADM_KEEP_BUILDS="${ADM_KEEP_BUILDS:-3}"    # keep last N builds per package
LOCK_DIR="${ADM_STATE}/locks"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# create required dirs (idempotent)
mkdir -p "${ADM_DIST_SRC}" "${ADM_BUILD_BASE}" "${ADM_PATCHES_DIR}" "${ADM_HOOKS_DIR}" "${ADM_LOGS}" "${ADM_STATE}" "${LOCK_DIR}"
chmod 755 "${ADM_DIST_SRC}" "${ADM_BUILD_BASE}" "${ADM_PATCHES_DIR}" "${ADM_HOOKS_DIR}" "${ADM_LOGS}" "${ADM_STATE}" "${LOCK_DIR}" 2>/dev/null || true

# ---- required commands ----
REQUIRED_CMDS=(tar sha256sum grep sed awk mkdir mv rm find mktemp cp patch git unzip cpio)
_missing=()
for c in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$c" >/dev/null 2>&1; then
    _missing+=("$c")
  fi
done
if [ "${#_missing[@]}" -ne 0 ]; then
  fatal "Missing required commands: ${_missing[*]}. Install them before running extract.sh"
fi
unset _missing

# ---- helpers ----
timestamp(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
logfile_for(){ local name="$1" version="$2"; printf "%s/extract-%s-%s.log" "${ADM_LOGS}" "${name}" "${version:-unknown}"; }

# parse simple key=value INI (returns value on stdout)
ini_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  awk -F= -v k="$key" '$0 ~ "^[[:space:]]*"k"=" { sub(/^[[:space:]]*/,""); sub(/[[:space:]]*=[[:space:]]*/,"="); print substr($0,index($0,"=")+1); exit }' "$file" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' || true
}

# find metafile: accepts full path, category/name, name (search)
find_metafile() {
  local arg="$1"
  # full path?
  [ -f "$arg" ] && { echo "$arg"; return 0; }
  # category/name
  if [ -f "${ADM_ROOT}/metafiles/${arg}/metafile" ]; then
    echo "${ADM_ROOT}/metafiles/${arg}/metafile"; return 0
  fi
  # search by name field
  find "${ADM_ROOT}/metafiles" -type f -name metafile 2>/dev/null | while read -r mf; do
    if ini_get "$mf" name 2>/dev/null | grep -xq "${arg}"; then
      echo "$mf"; exit 0
    fi
  done | head -n1
}

# compute sha256
sha256(){ sha256sum "$1" | awk '{print $1}'; }

# lock mechanism simple
acquire_lock() {
  local lock="$1"
  mkdir -p "$(dirname "$lock")"
  exec 9>"$lock"
  if ! flock -n 9; then
    return 1
  fi
  # store pid inside file for debugging
  printf "%s\n" "$$" 1>&9
  return 0
}
release_lock() {
  local lock="$1"
  # closing fd9 will release
  # safe best-effort: find and release
  # Nothing required; subshell will close on exit
  true
}

# locate source file in cache. returns path or empty
locate_source_file() {
  local name="$1" version="$2"
  # candidate patterns: name-version.*
  shopt -s nullglob
  local pattern1="${ADM_DIST_SRC}/${name}-${version}*"
  local lst=($pattern1)
  if [ ${#lst[@]} -gt 0 ]; then
    # return first that looks like archive/git
    for f in "${lst[@]}"; do
      echo "$f"; return 0
    done
  fi
  # fallback: any file that contains name and version
  for f in "${ADM_DIST_SRC}"/*; do
    if [[ "$(basename "$f")" == *"${name}"* ]] && [[ "$(basename "$f")" == *"${version}"* ]]; then
      echo "$f"; return 0
    fi
  done
  shopt -u nullglob
  return 1
}

# verify source file matches sha (sha optional)
verify_source_file() {
  local file="$1" expected_sha="$2"
  [ -f "$file" ] || return 2
  if [ -n "$expected_sha" ]; then
    local got
    got="$(sha256 "$file")"
    if [ "$got" = "$expected_sha" ]; then
      return 0
    else
      return 1
    fi
  fi
  return 0
}

# prepare unique tempdir for extraction
mk_tmpdir(){ mktemp -d "${ADM_ROOT}/tmp/extract-${1:-pkg}-XXXXXXXX"; }

# detect archive type for extraction
archive_type() {
  local file="$1"
  local b="$(basename "$file")"
  case "$b" in
    *.tar.gz|*.tgz) echo "tar.gz" ;;
    *.tar.xz) echo "tar.xz" ;;
    *.tar.bz2) echo "tar.bz2" ;;
    *.tar.zst|*.tar.zstd) echo "tar.zst" ;;
    *.tar.lz4) echo "tar.lz4" ;;
    *.tar) echo "tar" ;;
    *.zip) echo "zip" ;;
    *.git|git+* ) echo "git" ;;
    *) 
      # fallback using file(1) not required; guess tar
      echo "unknown"
      ;;
  esac
}

# extract archive into targetdir
extract_archive() {
  local file="$1" target="$2" logfile="$3"
  local atype; atype="$(archive_type "$file")"
  case "$atype" in
    tar.gz)
      tar -xzf "$file" -C "$target" >> "${logfile}" 2>&1
      ;;
    tar.xz)
      tar -xJf "$file" -C "$target" >> "${logfile}" 2>&1
      ;;
    tar.bz2)
      tar -xjf "$file" -C "$target" >> "${logfile}" 2>&1
      ;;
    tar.zst)
      tar --use-compress-program="zstd -d" -xf "$file" -C "$target" >> "${logfile}" 2>&1
      ;;
    tar.lz4)
      tar --use-compress-program="lz4 -d" -xf "$file" -C "$target" >> "${logfile}" 2>&1
      ;;
    tar)
      tar -xf "$file" -C "$target" >> "${logfile}" 2>&1
      ;;
    zip)
      unzip -q "$file" -d "$target" >> "${logfile}" 2>&1
      ;;
    unknown)
      # try tar auto-detect
      tar -xf "$file" -C "$target" >> "${logfile}" 2>&1 || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# clone or update git-ish url into targetdir
fetch_git_repo() {
  local url="$1" target="$2" logfile="$3"
  if [ -d "${target}/.git" ]; then
    (cd "$target" && git fetch --all --prune >> "${logfile}" 2>&1 && git reset --hard origin/HEAD >> "${logfile}" 2>&1) || return 1
  else
    git clone --depth 1 "$url" "$target" >> "${logfile}" 2>&1 || return 1
  fi
}

# detect probable build root inside extracted tempdir
detect_build_root() {
  local extractdir="$1"
  # look for single top-level dir
  local tl
  tl=()
  while IFS= read -r -d $'\0' d; do tl+=("$(basename "$d")"); done < <(find "$extractdir" -maxdepth 1 -mindepth 1 -type d -print0)
  if [ ${#tl[@]} -eq 1 ]; then
    echo "${tl[0]}"
    return 0
  fi
  # if many, choose one that contains configure/CMakeLists.txt/Makefile
  for d in "${tl[@]}"; do
    if [ -f "${extractdir}/${d}/configure" ] || [ -f "${extractdir}/${d}/CMakeLists.txt" ] || [ -f "${extractdir}/${d}/Makefile" ]; then
      echo "${d}"; return 0
    fi
  done
  # as fallback, choose the largest dir by filesize (heuristic)
  local best=""
  local bestsize=0
  for d in "${tl[@]}"; do
    local s
    s=$(du -s "${extractdir}/${d}" 2>/dev/null | awk '{print $1}' || echo 0)
    if [ "$s" -gt "$bestsize" ]; then bestsize="$s"; best="$d"; fi
  done
  [ -n "$best" ] && { echo "$best"; return 0; }
  # else use extractdir itself (files directly)
  echo "."
  return 0
}

# apply patches found in default locations
apply_patches_auto() {
  local name="$1" builddir="$2" logfile="$3"
  local patches_dir_pkg="${ADM_PATCHES_DIR}/${name}"
  local local_patches_dir="${builddir}/patches"
  local applied=0 failed=0
  for pd in "${patches_dir_pkg}" "${local_patches_dir}"; do
    [ -d "$pd" ] || continue
    info "Applying patches from ${pd}..."
    # sort files
    while IFS= read -r -d '' pf; do
      # only .patch or .diff or *.sh
      case "$(basename "$pf")" in
        *.patch|*.diff)
          if patch -d "$builddir" -p1 < "$pf" >> "${logfile}" 2>&1; then
            ok "Applied patch $(basename "$pf")"
            applied=$((applied+1))
          else
            warn "Patch failed: $(basename "$pf")"
            failed=$((failed+1))
            # if filename contains 'critical' mark as fatal
            if echo "$pf" | grep -qi 'critical'; then
              err "Critical patch failed: $(basename "$pf")"
              return 2
            fi
          fi
          ;;
        *.sh)
          # executable script patch - run in builddir
          if chmod +x "$pf" && (cd "$builddir" && "$pf" prepatch) >> "${logfile}" 2>&1; then
            ok "Ran patch script $(basename "$pf")"
            applied=$((applied+1))
          else
            warn "Patch script failed: $(basename "$pf")"
            failed=$((failed+1))
          fi
          ;;
        *) ;; # ignore
      esac
    done < <(find "$pd" -type f -maxdepth 1 -print0 | sort -z) 
  done
  printf "%s|%s\n" "$applied" "$failed"
  return 0
}

# record extraction metadata
record_extraction_state() {
  local name="$1" version="$2" category="$3" status="$4" builddir="$5"
  mkdir -p "${ADM_STATE}"
  local meta="${ADM_STATE}/extract-${name}-${version}.meta"
  {
    echo "name=${name}"
    echo "version=${version}"
    echo "category=${category}"
    echo "status=${status}"
    echo "build_dir=${builddir}"
    echo "timestamp=$(timestamp)"
  } > "${meta}"
  # update summary DB (append unique line)
  local db="${ADM_STATE}/extract.db"
  # remove existing same name/version
  grep -v "^${name}|${version}|" "${db}" 2>/dev/null || true > "${db}.tmp" || true
  printf "%s|%s|%s|%s|%s\n" "${name}" "${version}" "${category}" "${status}" "$(timestamp)" >> "${db}.tmp"
  mv -f "${db}.tmp" "${db}" 2>/dev/null || true
}

# run hooks (pre/post/error)
run_hooks_phase() {
  local phase="$1" name="$2" version="$3" category="$4"
  [ -d "${ADM_HOOKS_DIR}" ] || return 0
  for h in "${ADM_HOOKS_DIR}"/*; do
    [ -x "$h" ] || continue
    case "$(basename "$h")" in
      *.sh)
        info "Running hook ${phase}: $h"
        if ! "$h" "${phase}" "${name}" "${version}" "${category}" >> "${ADM_LOGS}/extract-hook-${name}-${version}.log" 2>&1; then
          warn "Hook ${h} returned non-zero (phase ${phase})"
        fi
        ;;
    esac
  done
}

# rotate old builds for a package (keep ADM_KEEP_BUILDS)
rotate_old_builds() {
  local pkgdir="$1" keep="${ADM_KEEP_BUILDS:-3}"
  [ -d "$pkgdir" ] || return 0
  # find subdirs sorted by mtime desc
  local items
  mapfile -t items < <(find "$pkgdir" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}')
  local idx=0
  for d in "${items[@]}"; do
    idx=$((idx+1))
    if [ "$idx" -gt "$keep" ]; then
      rm -rf "$d" || warn "Failed to remove old build $d"
      info "Removed old build $d"
    fi
  done
}

# main single-extract routine
extract_one_metafile() {
  local mf="$1"
  [ -f "$mf" ] || { err "Metafile not found: $mf"; return 2; }
  local name version category srcurl expected_sha srcfile logfile tmpdir extractdir buildroot buildname lockfile applied failed
  name=$(ini_get "$mf" name || true)
  version=$(ini_get "$mf" version || true)
  category=$(ini_get "$mf" category || echo "misc")
  srcurl=$(ini_get "$mf" source_url || ini_get "$mf" url || true)
  expected_sha=$(ini_get "$mf" source_sha256 || ini_get "$mf" source_sha || true)
  logfile="$(logfile_for "$name" "$version")"
  info "Starting extraction: ${name}-${version} (category: ${category})"
  info "Log: ${logfile}"

  # lock per-package to avoid concurrent extracts
  lockfile="${LOCK_DIR}/extract-${name}.lock"
  if ! acquire_lock "${lockfile}"; then
    warn "Another extract for ${name} is running (lock: ${lockfile})"
    return 3
  fi

  # find cached source file
  srcfile="$(locate_source_file "$name" "$version" || true)"
  if [ -z "${srcfile}" ]; then
    if [ "${ADM_OFFLINE}" = "1" ]; then
      err "Source for ${name}-${version} not present in cache and offline mode is enabled"
      release_lock "${lockfile}" || true
      return 4
    fi
    # try fetching using fetch.sh if available
    if [ -x "${ADM_SCRIPTS_DIR}/fetch.sh" ]; then
      info "Source not found locally. Attempting to fetch via fetch.sh..."
      if ! bash "${ADM_SCRIPTS_DIR}/fetch.sh" get "$mf" >> "${logfile}" 2>&1; then
        err "fetch.sh failed to retrieve source for ${name}; see ${logfile}"
        release_lock "${lockfile}" || true
        return 5
      fi
      srcfile="$(locate_source_file "$name" "$version" || true)"
      if [ -z "${srcfile}" ]; then
        err "fetch.sh did not produce a source file for ${name}"
        release_lock "${lockfile}" || true
        return 6
      fi
    else
      err "No fetch.sh present to retrieve source and file not found locally"
      release_lock "${lockfile}" || true
      return 7
    fi
  fi

  # verify checksum if provided
  if [ -n "${expected_sha}" ]; then
    if verify_source_file "$srcfile" "$expected_sha"; then
      ok "Checksum valid for $(basename "$srcfile")"
    else
      warn "Checksum mismatch for $(basename "$srcfile"). Will remove and re-fetch."
      rm -f "$srcfile"
      # try fetch once
      if [ "${ADM_OFFLINE}" = "1" ]; then
        err "Offline mode: cannot re-fetch ${name}"
        release_lock "${lockfile}" || true
        return 8
      fi
      if [ -x "${ADM_SCRIPTS_DIR}/fetch.sh" ]; then
        if ! bash "${ADM_SCRIPTS_DIR}/fetch.sh" update "$mf" >> "${logfile}" 2>&1; then
          err "fetch.sh update failed for ${name}"
          release_lock "${lockfile}" || true
          return 9
        fi
        srcfile="$(locate_source_file "$name" "$version" || true)"
        if [ -z "${srcfile}" ]; then
          err "fetch.sh update did not produce source file for ${name}"
          release_lock "${lockfile}" || true
          return 10
        fi
        if ! verify_source_file "$srcfile" "$expected_sha"; then
          err "Re-fetched file checksum still invalid for ${name}"
          release_lock "${lockfile}" || true
          return 11
        fi
      else
        err "No fetch.sh to re-fetch corrupted file"
        release_lock "${lockfile}" || true
        return 12
      fi
    fi
  else
    ok "No expected SHA provided; skipping checksum check"
  fi

  # prepare temporary extraction dir and final build dir
  tmpdir="$(mk_tmpdir "${name}-${version}")"
  info "Created temporary dir: ${tmpdir}"
  trap 'rm -rf "${tmpdir}" 2>/dev/null || true' EXIT

  # extract
  if [[ "$(archive_type "$srcfile")" == "git" ]] || [[ "$srcurl" == git+* ]]; then
    # handle git URL in srcurl or file path
    local repourl="${srcurl}"
    if [[ "$repourl" == git+* ]]; then repourl="${repourl#git+}"; fi
    fetch_git_repo "$repourl" "${tmpdir}/source" "${logfile}" || { err "git clone failed"; rm -rf "${tmpdir}"; release_lock "${lockfile}"; return 13; }
    extract_dir="${tmpdir}/source"
  else
    # extract archive into tmpdir/extract
    mkdir -p "${tmpdir}/extract"
    if ! extract_archive "$srcfile" "${tmpdir}/extract" "${logfile}"; then
      err "Extraction failed for ${srcfile}; see ${logfile}"
      rm -rf "${tmpdir}"
      release_lock "${lockfile}"
      return 14
    fi
    # detect build root inside extract
    local br
    br="$(detect_build_root "${tmpdir}/extract")"
    if [ "$br" = "." ]; then
      extract_dir="${tmpdir}/extract"
    else
      extract_dir="${tmpdir}/extract/${br}"
    fi
  fi

  # identify final builddir path
  buildroot="${ADM_BUILD_BASE}/${category}/${name}-${version}"
  mkdir -p "$(dirname "${buildroot}")"
  # rotate old builds if configured
  if [ "${ADM_CLEAN_OLD_BUILDS}" -eq 1 ]; then
    rotate_old_builds "${ADM_BUILD_BASE}/${category}/${name}"
  fi

  # move extracted content atomically to buildroot
  if [ -d "${buildroot}" ]; then
    info "Existing build dir ${buildroot} found. Renaming to keep history."
    local backup="${buildroot}.bak.${TIMESTAMP}"
    mv "${buildroot}" "${backup}" || warn "Failed to backup existing build dir (continuing)"
  fi
  mv "${extract_dir}" "${buildroot}" >> "${logfile}" 2>&1 || { err "Failed to move extracted tree to ${buildroot}"; rm -rf "${tmpdir}"; release_lock "${lockfile}"; return 15; }
  ok "Extracted to ${buildroot}"

  # apply patches automatically
  local pfres
  pfres="$(apply_patches_auto "$name" "$buildroot" "$logfile")" || true
  applied="$(echo "$pfres" | head -n1 | cut -d'|' -f1 || echo 0)"
  failed="$(echo "$pfres" | head -n1 | cut -d'|' -f2 || echo 0)"
  info "Patches applied: ${applied}, failed: ${failed}"

  # run post-extract hooks
  run_hooks_phase post "$name" "$version" "$category"

  # record success state
  record_extraction_state "$name" "$version" "$category" "ok" "$buildroot"
  ok "Extraction completed for ${name}-${version}"
  # cleanup tmpdir (trap will clean)
  rm -rf "${tmpdir}" || true
  trap - EXIT

  release_lock "${lockfile}" || true
  return 0
}

# batch commands
cmd_extract() {
  local arg="$1"
  mf="$(find_metafile "$arg" || true)"
  [ -n "${mf:-}" ] || fatal "Metafile not found for ${arg}"
  extract_one_metafile "$mf"
}

cmd_category() {
  local cat="$1"
  local dir="${ADM_ROOT}/metafiles/${cat}"
  [ -d "$dir" ] || fatal "Category not found: $cat"
  shopt -s nullglob
  local mfs=("$dir"/**/metafile "$dir"/metafile)
  # simpler: find metafile files under category
  mapfile -t mfs < <(find "$dir" -type f -name metafile 2>/dev/null)
  for mf in "${mfs[@]}"; do
    extract_one_metafile "$mf" || warn "Extract failed for $(basename "$mf")"
  done
  shopt -u nullglob
}

cmd_all() {
  mapfile -t mfs < <(find "${ADM_ROOT}/metafiles" -type f -name metafile 2>/dev/null)
  for mf in "${mfs[@]}"; do
    extract_one_metafile "$mf" || warn "Extract failed for $(basename "$mf")"
  done
}

cmd_verify() {
  local target="$1"
  local mf
  mf="$(find_metafile "$target" || true)"
  [ -n "${mf:-}" ] || fatal "Metafile not found for ${target}"
  local name version expected_sha srcfile
  name="$(ini_get "$mf" name || true)"; version="$(ini_get "$mf" version || true)"
  expected_sha="$(ini_get "$mf" source_sha256 || ini_get "$mf" source_sha || true)"
  srcfile="$(locate_source_file "$name" "$version" || true)"
  if [ -z "$srcfile" ]; then
    echo "Source file not present locally for ${name}-${version}"
    return 2
  fi
  if [ -n "$expected_sha" ]; then
    if verify_source_file "$srcfile" "$expected_sha"; then
      ok "Verified ${srcfile}"
      return 0
    else
      err "Checksum mismatch for ${srcfile}"
      return 1
    fi
  else
    warn "No expected sha in metafile; cannot fully verify"
    return 3
  fi
}

cmd_clean() {
  info "Cleaning old builds per configuration..."
  # iterate categories
  for pkgd in "${ADM_BUILD_BASE}"/*/*; do
    [ -d "$pkgd" ] || continue
    rotate_old_builds "$pkgd"
  done
  ok "Clean complete"
}

usage() {
  cat <<EOF
extract.sh - ADM intelligent extract utility

Usage:
  extract.sh <metafile|category/name|name>    Extract single package (metafile or identifier)
  extract.sh --category <category>            Extract all packages in that category
  extract.sh --all                            Extract all packages
  extract.sh --verify <metafile|name>         Verify cached source SHA
  extract.sh --clean                          Clean old build dirs
  extract.sh --help                           Show this help

Notes:
  - Metafiles expected at ${ADM_ROOT}/metafiles/<category>/<pkg>/metafile
  - Patches (optional) are read from ${ADM_PATCHES_DIR}/<name>/ and <build_dir>/patches/
  - Hooks in ${ADM_HOOKS_DIR} are executed (pre/post)
  - If source is missing and ADM_OFFLINE=0, fetch.sh (if present) will be invoked automatically
EOF
}

# dispatcher
case "${1-}" in
  --category) [ -n "${2-}" ] || fatal "--category requires argument"; cmd_category "$2" ;;
  --all) cmd_all ;;
  --verify) [ -n "${2-}" ] || fatal "--verify requires argument"; cmd_verify "$2" ;;
  --clean) cmd_clean ;;
  --help|-h|help|"") usage ;;
  *)
    if [ -n "${1-}" ]; then
      cmd_extract "$1"
    else
      usage
    fi
    ;;
esac

exit 0
