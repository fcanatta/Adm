#!/usr/bin/env bash
# ======================================================================
# /usr/src/adm/scripts/detect-builder.sh
# ADM — Universal Build Detector (PROD, final)
# Generates a comprehensive build-plan JSON for any project (kernel, firmware,
# kernel modules, autotools, cmake, meson, cargo, go, python, node, etc).
# Output: /usr/src/adm/state/buildplans/*.json
# Logs:   /usr/src/adm/logs/detect-builder-<timestamp>.log
# Requirements: bash, coreutils, python3, mktemp, sha256sum
# ======================================================================
set -euo pipefail
IFS=$'\n\t'

# -------------------------
# Configuration (override with env)
# -------------------------
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_SCRIPTS_DIR="${ADM_SCRIPTS_DIR:-${ADM_ROOT}/scripts}"
ADM_LOGS="${ADM_LOGS:-${ADM_ROOT}/logs}"
ADM_STATE="${ADM_STATE:-${ADM_ROOT}/state}"
ADM_TMP="${ADM_TMP:-${ADM_ROOT}/tmp}"
ADM_BUILD_PLAN_DIR="${ADM_BUILD_PLAN_DIR:-${ADM_STATE}/buildplans}"
ADM_PROFILE="${ADM_PROFILE:-performance}"   # minimal|balance|performance|debug
PROFILE_SH="${ADM_SCRIPTS_DIR}/profile.sh"
HOOKS_SH="${ADM_SCRIPTS_DIR}/hooks.sh"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOGFILE="${ADM_LOGS}/detect-builder-${TIMESTAMP}.log"
BUILDERS_DB="${ADM_STATE}/builders.db"
KEEP_LOGS_DAYS="${KEEP_LOGS_DAYS:-30}"

# ensure dirs
mkdir -p "${ADM_LOGS}" "${ADM_STATE}" "${ADM_TMP}" "${ADM_BUILD_PLAN_DIR}"
chmod 755 "${ADM_LOGS}" "${ADM_STATE}" "${ADM_TMP}" "${ADM_BUILD_PLAN_DIR}" 2>/dev/null || true

# -------------------------
# Colors & logging helpers
# -------------------------
COL_RST="\033[0m"; COL_INFO="\033[1;34m"; COL_OK="\033[1;32m"; COL_WARN="\033[1;33m"; COL_ERR="\033[1;31m"
log()  { printf "%b[INFO]%b  %s\n"  "${COL_INFO}" "${COL_RST}" "$*" | tee -a "${LOGFILE}"; }
ok()   { printf "%b[ OK ]%b  %s\n"  "${COL_OK}" "${COL_RST}" "$*" | tee -a "${LOGFILE}"; }
warn() { printf "%b[WARN]%b  %s\n" "${COL_WARN}" "${COL_RST}" "$*" | tee -a "${LOGFILE}"; }
err()  { printf "%b[ERR ]%b  %s\n"  "${COL_ERR}" "${COL_RST}" "$*" | tee -a "${LOGFILE}"; }
fatal(){ printf "%b[FATAL]%b %s\n" "${COL_ERR}" "${COL_RST}" "$*" | tee -a "${LOGFILE}"; exit 1; }

trap 'err "detect-builder aborted at line ${LINENO}"; exit 2' ERR INT TERM

# -------------------------
# Dependency checks
# -------------------------
_required=(awk sed grep find tar xargs uname stat date sha256sum mktemp python3)
_missing=()
for c in "${_required[@]}"; do
  if ! command -v "$c" >/dev/null 2>&1; then _missing+=("$c"); fi
done
if [ "${#_missing[@]}" -ne 0 ]; then
  fatal "Missing required commands: ${_missing[*]}. Install them and retry."
fi
HAS_JQ=0
if command -v jq >/dev/null 2>&1; then HAS_JQ=1; fi

# -------------------------
# small helpers
# -------------------------
timestamp(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
sanitized_abspath(){
  local p="$1"
  [ -z "$p" ] && { echo ""; return; }
  if [ ! -e "$p" ]; then fatal "Path does not exist: $p"; fi
  local abs
  abs="$(cd "$p" 2>/dev/null && pwd -P)" || fatal "Cannot resolve path: $p"
  echo "$abs"
}
atomic_write(){
  local content="$1"; local out="$2"
  local tmpf
  tmpf="$(mktemp "${out}.tmp.XXXX")"
  printf "%s\n" "$content" > "$tmpf"
  mv -f "$tmpf" "$out"
  ok "Wrote: $out"
}
record_db(){
  local pkg="$1" ver="$2" ptype="$3" sys="$4" status="$5" planpath="$6"
  mkdir -p "$(dirname "${BUILDERS_DB}")"
  printf "%s|%s|%s|%s|%s|%s|%s\n" "$(timestamp)" "$pkg" "$ver" "$ptype" "$sys" "$status" "$planpath" >> "${BUILDERS_DB}"
}
run_hooks(){
  local phase="$1" step="$2" ref="${3:-}"
  if [ -x "${HOOKS_SH}" ]; then
    log "Running hooks: ${HOOKS_SH} run ${phase} ${step} ${ref}"
    if ! bash "${HOOKS_SH}" run "${phase}" "${step}" "${ref}" >>"${LOGFILE}" 2>&1; then
      warn "hooks.sh returned non-zero (see ${LOGFILE})"
    fi
  fi
}

# safe grep helper returns nothing if not found (exit 0)
safe_grep(){ grep -R --binary-files=without-match -I "$1" "${2:-.}" 2>/dev/null || true; }

# -------------------------
# rotate old logs (keep KEEP_LOGS_DAYS)
# -------------------------
( find "${ADM_LOGS}" -name 'detect-builder-*.log' -mtime +"${KEEP_LOGS_DAYS}" -print -exec rm -f {} \; ) 2>/dev/null || true
# -------------------------
# determine build root
# -------------------------
detect_build_root(){
  local arg="$1"
  if [ -z "$arg" ]; then fatal "Usage: detect-builder.sh <build-dir|metafile>"; fi
  # if directory passed
  if [ -d "$arg" ]; then echo "$(sanitized_abspath "$arg")"; return 0; fi
  # if metafile passed: try to infer
  if [ -f "$arg" ]; then
    local name ver cat
    name="$(awk -F= '/^name=/{gsub(/^[ \t]+|[ \t]+$/,"",$2);print $2;exit}' "$arg" 2>/dev/null || true)"
    ver="$(awk -F= '/^version=/{gsub(/^[ \t]+|[ \t]+$/,"",$2);print $2;exit}' "$arg" 2>/dev/null || true)"
    cat="$(awk -F= '/^category=/{gsub(/^[ \t]+|[ \t]+$/,"",$2);print $2;exit}' "$arg" 2>/dev/null || true)"
    if [ -n "$name" ] && [ -n "$ver" ] && [ -d "${ADM_ROOT}/build/${cat:-misc}/${name}-${ver}" ]; then
      echo "$(sanitized_abspath "${ADM_ROOT}/build/${cat:-misc}/${name}-${ver}")"; return 0
    fi
  fi
  fatal "Cannot determine build root from: ${arg}"
}

# -------------------------
# detect build system
# -------------------------
detect_build_system(){
  local d="$1"
  # kernel detection
  if [ -f "${d}/Kconfig" ] || [ -f "${d}/init/main.c" ] || ( [ -f "${d}/Makefile" ] && grep -Eq 'KBUILD' "${d}/Makefile" 2>/dev/null ); then
    echo "kernel"; return 0
  fi
  [ -f "${d}/meson.build" ] && { echo "meson"; return 0; }
  [ -f "${d}/CMakeLists.txt" ] && { echo "cmake"; return 0; }
  [ -f "${d}/configure" ] || [ -f "${d}/configure.ac" ] && { echo "autotools"; return 0; }
  [ -f "${d}/Cargo.toml" ] && { echo "cargo"; return 0; }
  [ -f "${d}/go.mod" ] && { echo "go"; return 0; }
  [ -f "${d}/setup.py" ] || [ -f "${d}/pyproject.toml" ] && { echo "python"; return 0; }
  [ -f "${d}/package.json" ] && { echo "node"; return 0; }
  [ -f "${d}/build.zig" ] && { echo "zig"; return 0; }
  safe_grep "obj-m" "$d" | grep -q . && { echo "kernel-module"; return 0; }
  [ -f "${d}/Makefile" ] && { echo "make"; return 0; }
  echo "unknown"
}

# -------------------------
# detect languages (fast heuristics)
# returns comma-separated list or "unknown"
# -------------------------
detect_languages(){
  local d="$1"
  local -A seen=()
  local out=()
  # limit depth to avoid scanning huge trees
  while IFS= read -r f; do
    case "$f" in
      *.c) seen[C]=1 ;;
      *.h) seen[C]=1 ;;
      *.cpp|*.cc|*.cxx) seen[CXX]=1 ;;
      *.rs) seen[Rust]=1 ;;
      *.go) seen[Go]=1 ;;
      *.py) seen[Python]=1 ;;
      *.java) seen[Java]=1 ;;
      *.kt) seen[Kotlin]=1 ;;
      *.js) seen[JS]=1 ;;
      *.ts) seen[TS]=1 ;;
      *.f90|*.f95|*.f) seen[Fortran]=1 ;;
      *.s|*.S) seen[Asm]=1 ;;
      *.nim) seen[Nim]=1 ;;
      *.jl) seen[Julia]=1 ;;
      *.hs) seen[Haskell]=1 ;;
    esac
  done < <(find "$d" -type f -maxdepth 6 -printf '%f\n' 2>/dev/null | sed -n '1,20000p' || true)
  for k in "${!seen[@]}"; do out+=("$k"); done
  if [ "${#out[@]}" -eq 0 ]; then echo "unknown"; else (IFS=','; echo "${out[*]}"); fi
}

# -------------------------
# detect dependencies (heuristic)
# -------------------------
detect_dependencies(){
  local d="$1"
  local deps=()
  if safe_grep "pkg-config" "$d" | grep -q .; then deps+=("pkg-config"); fi
  if safe_grep -E "openssl|<openssl/" "$d" | grep -q .; then deps+=("openssl"); fi
  if safe_grep -E "gtk|gtk3|gtk\-3" "$d" | grep -q .; then deps+=("gtk"); fi
  if safe_grep -E "QtCore|QWidget|<Q" "$d" | grep -q .; then deps+=("qt"); fi
  if safe_grep -E "libudev|udev" "$d" | grep -q .; then deps+=("libudev"); fi
  if [ ${#deps[@]} -eq 0 ]; then echo "none"; else (IFS=','; echo "${deps[*]}"); fi
}

# -------------------------
# detect special type (kernel, firmware, module, normal)
# -------------------------
detect_special_type(){
  local d="$1"
  if [ -f "${d}/Kconfig" ] || [ -f "${d}/init/main.c" ]; then echo "kernel"; return 0; fi
  if [ -d "${d}/firmware" ] || safe_grep "firmware" "$d" | grep -q .; then echo "firmware"; return 0; fi
  if safe_grep "obj-m" "$d" | grep -q .; then echo "kernel-module"; return 0; fi
  echo "normal"
}

# -------------------------
# discover patches in /usr/src/adm/patches/<name> or metafile dir (returns newline paths)
# -------------------------
discover_patches(){
  local d="$1"
  local name; name="$(basename "$d")"
  local patches_dir="${ADM_ROOT}/patches/${name}"
  if [ -d "${patches_dir}" ]; then
    find "${patches_dir}" -type f -iname '*.patch' -printf '%p\n' 2>/dev/null | sort || true
  else
    # check for patches next to project (metafiles)
    if [ -d "${d}/patches" ]; then
      find "${d}/patches" -type f -iname '*.patch' -printf '%p\n' 2>/dev/null | sort || true
    fi
  fi
}
# -------------------------
# apply patches (in order). Returns 0 on success, 1 on failure.
# Writes to LOGFILE full patch output. Does not modify original tarballs.
# -------------------------
apply_patches(){
  local d="$1"
  local p
  mapfile -t patches < <(discover_patches "$d" || true)
  if [ "${#patches[@]}" -eq 0 ]; then return 0; fi
  log "Applying ${#patches[@]} patches for $(basename "$d")"
  for p in "${patches[@]}"; do
    if patch -p1 -d "$d" --dry-run < "$p" >>"${LOGFILE}" 2>&1; then
      if patch -p1 -d "$d" < "$p" >>"${LOGFILE}" 2>&1; then
        ok "Applied patch: $(basename "$p")"
      else
        err "Failed to apply patch: $(basename "$p") (see ${LOGFILE})"
        return 1
      fi
    else
      warn "Patch did not apply cleanly (dry-run failed): $(basename "$p")"
      # attempt three-way fuzzless apply to give best-effort
      if git -C "$d" apply --check --index "$p" >>"${LOGFILE}" 2>&1; then
        git -C "$d" apply "$p" >>"${LOGFILE}" 2>&1 || { err "git apply failed for $p"; return 1; }
        ok "Applied patch via git apply: $(basename "$p")"
      else
        warn "Skipping patch (did not apply): $(basename "$p")"
      fi
    fi
  done
  return 0
}

# -------------------------
# merge kernel config fragments (if any)
# Uses scripts/kconfig/merge_config.sh if present, otherwise concatenates fragments carefully.
# -------------------------
merge_kernel_config_fragments(){
  local d="$1"
  local fragdir="${d}/kernel-config"
  if [ ! -d "$fragdir" ]; then fragdir="${d}/config.d"; fi
  [ -d "$fragdir" ] || return 0
  # prefer kernel's merge tool
  if [ -x "${d}/scripts/kconfig/merge_config.sh" ]; then
    log "Merging kernel config fragments via scripts/kconfig/merge_config.sh"
    if ! "${d}/scripts/kconfig/merge_config.sh" "${d}/.config" "${fragdir}"/*.cfg >>"${LOGFILE}" 2>&1; then
      err "merge_config.sh failed; see ${LOGFILE}"
      return 1
    fi
    ok "Kernel config fragments merged"
    return 0
  fi
  # fallback: conservative merge - append only options not present
  log "Merging kernel fragments by conservative append (no merge tool)"
  touch "${d}/.config"
  local tmp="$(mktemp)"
  cp "${d}/.config" "$tmp"
  for f in "${fragdir}"/*.cfg; do
    [ -f "$f" ] || continue
    awk 'NR==FNR{a[$1]=1; next} !($1 in a){print}' "$tmp" "$f" >> "${tmp}.append"
  done
  if [ -f "${tmp}.append" ]; then
    cat "${tmp}.append" >> "${d}/.config"
    ok "Appended kernel config fragments"
    rm -f "${tmp}.append"
  else
    ok "No new fragments to append"
  fi
  rm -f "$tmp" || true
  return 0
}

# -------------------------
# kernel sanity checks (headers, KERNEL_SRC)
# -------------------------
kernel_toolchain_check(){
  local ksrc="${KERNEL_SRC:-/lib/modules/$(uname -r)/build}"
  if [ ! -d "$ksrc" ]; then
    warn "KERNEL_SRC ($ksrc) not found. Some modules/kernel builds may fail."
    return 1
  fi
  ok "KERNEL_SRC found: $ksrc"
  return 0
}

# -------------------------
# validate toolchain for system type (returns 0 if OK)
# -------------------------
validate_toolchain_from_system(){
  local sys="$1"
  local reqs=()
  case "$sys" in
    kernel) reqs=(gcc make bc perl);;
    "kernel-module") reqs=(gcc make);;
    meson) reqs=(meson ninja gcc);;
    cmake) reqs=(cmake make gcc);;
    autotools) reqs=(autoreconf autoconf automake make gcc);;
    cargo) reqs=(cargo rustc);;
    go) reqs=(go);;
    python) reqs=(python3 pip);;
    node) reqs=(node npm);;
    zig) reqs=(zig);;
    *) reqs=(make gcc);;
  esac
  local miss=()
  for t in "${reqs[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then miss+=("$t"); fi
  done
  if [ "${#miss[@]}" -ne 0 ]; then
    err "Missing toolchain components: ${miss[*]}"
    return 1
  fi
  # additional kernel check
  if [ "$sys" = "kernel" ] || [ "$sys" = "kernel-module" ]; then
    kernel_toolchain_check || return 1
  fi
  ok "Toolchain validated for ${sys}"
  return 0
}

# -------------------------
# prepare environment variables according to profile
# -------------------------
prepare_profile_env(){
  # default safe flags; profiles can override via PROFILE_SH exporting CFLAGS etc.
  CFLAGS_DEFAULT="-O2 -pipe -fstack-protector-strong -fno-plt"
  LDFLAGS_DEFAULT="-Wl,-O1 -Wl,--as-needed"
  MAKEFLAGS_DEFAULT=""
  case "${ADM_PROFILE}" in
    minimal)
      export CFLAGS="${CFLAGS:-"-O1 -pipe"}"
      export LDFLAGS="${LDFLAGS:-"-Wl,--as-needed"}"
      export MAKEFLAGS="${MAKEFLAGS:-"-j1"}"
      ;;
    balance)
      export CFLAGS="${CFLAGS:-"${CFLAGS_DEFAULT}"}"
      export LDFLAGS="${LDFLAGS:-"${LDFLAGS_DEFAULT}"}"
      export MAKEFLAGS="${MAKEFLAGS:-"-j$(nproc --all)/2"}"
      ;;
    performance)
      export CFLAGS="${CFLAGS:-"${CFLAGS_DEFAULT} -march=native -flto"}"
      export LDFLAGS="${LDFLAGS:-"${LDFLAGS_DEFAULT} -flto"}"
      export MAKEFLAGS="${MAKEFLAGS:-"-j$(nproc --all)"}"
      ;;
    debug)
      export CFLAGS="${CFLAGS:-"-O0 -g"}"
      export LDFLAGS="${LDFLAGS:-""}"
      export MAKEFLAGS="${MAKEFLAGS:-"-j1"}"
      ;;
    *)
      export CFLAGS="${CFLAGS:-"${CFLAGS_DEFAULT}"}"
      export LDFLAGS="${LDFLAGS:-"${LDFLAGS_DEFAULT}"}"
      export MAKEFLAGS="${MAKEFLAGS:-""}"
      ;;
  esac
  # source PROFILE_SH if exists (it may override)
  if [ -x "${PROFILE_SH}" ]; then
    # shellcheck disable=SC1090
    source "${PROFILE_SH}" >/dev/null 2>&1 || warn "profile.sh exists but failed to source"
  fi
}
# -------------------------
# generate concrete build-plan (no placeholders)
# Returns JSON string printed to stdout
# -------------------------
generate_build_plan(){
  local d="$1" sys="$2" langs="$3" special="$4"
  prepare_profile_env

  local name ver category jobs staging
  name="$(basename "$d")"
  # try to extract version heuristically (common pattern: name-version)
  ver="$(basename "$d" | sed -n 's/^.*-\([0-9][0-9a-zA-Z_.-]*\)$/\1/p' || true)"
  [ -n "$ver" ] || ver="$(date -u +%Y%m%dT%H%M%SZ)"
  category="unknown"

  jobs="$(nproc --all 2>/dev/null || echo 1)"
  case "${ADM_PROFILE}" in
    minimal) jobs=1 ;;
    balance) jobs=$(( jobs>2 ? jobs/2 : jobs )) ;;
    performance) jobs="$jobs" ;;
    debug) jobs=1 ;;
  esac

  staging="$(mktemp -d "${ADM_TMP}/staging-${name}-${TIMESTAMP}.XXXX")"
  mkdir -p "${staging}"

  # apply patches pre-detection for many systems (best-effort)
  if ! apply_patches "$d"; then
    warn "One or more patches failed (see ${LOGFILE}); build-plan will continue but may fail at build time."
  fi

  local pre_cmd=""
  local configure_cmd=""
  local build_cmd=""
  local install_cmd=""
  local post_cmd=""
  local toolchain_checks_arr=()

  case "$sys" in
    kernel)
      merge_kernel_config_fragments "$d" || warn "Kernel config fragment merge failed"
      pre_cmd="(mkdir -p '${staging}/boot' '${staging}/lib/modules' || true)"
      configure_cmd="(cd '${d}' && if [ -f .config ]; then echo '.config exists'; else yes '' | make olddefconfig >/dev/null 2>&1 || make defconfig >/dev/null 2>&1; fi )"
      build_cmd="(cd '${d}' && make -j${jobs} 2>&1 | tee '${LOGFILE}.kernel-build')"
      install_cmd="(cd '${d}' && make modules_install INSTALL_MOD_PATH='${staging}' 2>&1 | tee '${LOGFILE}.modules-install' && cp -a ${d}/arch/*/boot/* '${staging}/boot/' 2>/dev/null || true)"
      post_cmd="(depmod -a -b '${staging}' || true)"
      toolchain_checks_arr=(gcc make bc perl)
      ;;
    kernel-module)
      pre_cmd="(mkdir -p '${staging}/lib/modules' || true)"
      configure_cmd="true"
      build_cmd="(make -C \"\${KERNEL_SRC:-/lib/modules/$(uname -r)/build}\" M='${d}' -j${jobs} modules 2>&1 | tee '${LOGFILE}.module-build')"
      install_cmd="(make -C \"\${KERNEL_SRC:-/lib/modules/$(uname -r)/build}\" M='${d}' INSTALL_MOD_PATH='${staging}' modules_install 2>&1 | tee '${LOGFILE}.module-install')"
      post_cmd="(depmod -a -b '${staging}' || true)"
      toolchain_checks_arr=(gcc make)
      ;;
    firmware)
      pre_cmd="mkdir -p '${staging}/lib/firmware'"
      configure_cmd="true"
      build_cmd="(if [ -f '${d}/Makefile' ]; then make -C '${d}' -j${jobs} 2>&1 | tee '${LOGFILE}.firmware-build'; fi )"
      install_cmd="(cp -a '${d}'/* '${staging}/lib/firmware/' 2>/dev/null || true)"
      post_cmd="true"
      toolchain_checks_arr=(tar)
      ;;
    meson)
      pre_cmd="mkdir -p '${d}/build'"
      configure_cmd="meson setup '${d}/build' --prefix=/usr 2>&1 | tee '${LOGFILE}.meson-config'"
      build_cmd="ninja -C '${d}/build' -j${jobs} 2>&1 | tee '${LOGFILE}.meson-build'"
      install_cmd="DESTDIR='${staging}' ninja -C '${d}/build' install 2>&1 | tee '${LOGFILE}.meson-install'"
      post_cmd="true"
      toolchain_checks_arr=(meson ninja gcc)
      ;;
    cmake)
      pre_cmd="mkdir -p '${d}/build'"
      configure_cmd="cmake -S '${d}' -B '${d}/build' -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr 2>&1 | tee '${LOGFILE}.cmake-config'"
      build_cmd="cmake --build '${d}/build' -- -j${jobs} 2>&1 | tee '${LOGFILE}.cmake-build'"
      install_cmd="cmake --install '${d}/build' --prefix /usr -- DESTDIR='${staging}' 2>&1 | tee '${LOGFILE}.cmake-install'"
      post_cmd="true"
      toolchain_checks_arr=(cmake make gcc)
      ;;
    autotools)
      configure_cmd="(cd '${d}' && if [ -f configure.ac ] && [ ! -f configure ]; then autoreconf -fi >/dev/null 2>&1 || true; fi; ./configure --prefix=/usr --sysconfdir=/etc --disable-static 2>&1 | tee '${LOGFILE}.autotools-config')"
      build_cmd="(cd '${d}' && make -j${jobs} 2>&1 | tee '${LOGFILE}.autotools-build')"
      install_cmd="(cd '${d}' && make install DESTDIR='${staging}' 2>&1 | tee '${LOGFILE}.autotools-install')"
      post_cmd="true"
      toolchain_checks_arr=(autoreconf autoconf automake make gcc)
      ;;
    cargo)
      configure_cmd="(cd '${d}' && cargo fetch --locked 2>&1 | tee '${LOGFILE}.cargo-fetch')"
      build_cmd="(cd '${d}' && cargo build --release -j ${jobs} 2>&1 | tee '${LOGFILE}.cargo-build')"
      install_cmd="cargo install --path '${d}' --root '${staging}' 2>&1 | tee '${LOGFILE}.cargo-install' || true"
      post_cmd="true"
      toolchain_checks_arr=(cargo rustc)
      ;;
    go)
      configure_cmd="true"
      build_cmd="(cd '${d}' && go build ./... 2>&1 | tee '${LOGFILE}.go-build')"
      install_cmd="(mkdir -p '${staging}/usr/bin' && cd '${d}' && for f in \$(find . -maxdepth 1 -type f -perm -u+x -printf '%f\n'); do cp -a \"\$f\" '${staging}/usr/bin/' || true; done)"
      post_cmd="true"
      toolchain_checks_arr=(go)
      ;;
    python)
      configure_cmd="python3 -m pip install --upgrade build 2>&1 | tee '${LOGFILE}.python-buildtool'"
      build_cmd="(cd '${d}' && python3 -m build --wheel --outdir '${staging}/wheels' 2>&1 | tee '${LOGFILE}.python-build')"
      install_cmd="python3 -m pip install . --root '${staging}' 2>&1 | tee '${LOGFILE}.python-install' || true"
      post_cmd="true"
      toolchain_checks_arr=(python3 pip)
      ;;
    node)
      configure_cmd="(cd '${d}' && npm ci 2>&1 | tee '${LOGFILE}.npm-ci')"
      build_cmd="(cd '${d}' && npm run build 2>&1 | tee '${LOGFILE}.npm-build' || true)"
      install_cmd="(cd '${d}' && npm pack && mkdir -p '${staging}/usr/lib/node_modules' && tar -xzf *.tgz -C '${staging}/usr/lib/node_modules' || true)"
      post_cmd="true"
      toolchain_checks_arr=(node npm)
      ;;
    make)
      configure_cmd="true"
      build_cmd="(cd '${d}' && make -j${jobs} 2>&1 | tee '${LOGFILE}.make-build')"
      install_cmd="(cd '${d}' && make install DESTDIR='${staging}' 2>&1 | tee '${LOGFILE}.make-install')"
      post_cmd="true"
      toolchain_checks_arr=(make gcc)
      ;;
    unknown)
      configure_cmd="true"
      build_cmd="(cd '${d}' && make -j${jobs} 2>&1 | tee '${LOGFILE}.unknown-build' || true)"
      install_cmd="(cd '${d}' && make install DESTDIR='${staging}' 2>&1 | tee '${LOGFILE}.unknown-install' || true)"
      post_cmd="true"
      toolchain_checks_arr=(make)
      ;;
  esac

  # Build the JSON using python3 for robust escaping
  python3 - <<PY
import json,sys
plan = {
  "detected_at": "$(timestamp)",
  "path": "$(sanitized_abspath "$d")",
  "name": "$(printf "%s" "$name")",
  "version": "$(printf "%s" "$ver")",
  "category": "$(printf "%s" "$category")",
  "system": "$(printf "%s" "$sys")",
  "special": "$(printf "%s" "$special")",
  "languages": "$(printf "%s" "$langs")",
  "dependencies": "$(printf "%s" "$(detect_dependencies "$d")")",
  "jobs": $jobs,
  "env": {
    "CFLAGS": "$(printf "%s" "${CFLAGS:-}")",
    "LDFLAGS": "$(printf "%s" "${LDFLAGS:-}")",
    "MAKEFLAGS": "$(printf "%s" "${MAKEFLAGS:-}")"
  },
  "pre_commands": "$(printf "%s" "$pre_cmd")",
  "configure": "$(printf "%s" "$configure_cmd")",
  "build": "$(printf "%s" "$build_cmd")",
  "install": "$(printf "%s" "$install_cmd")",
  "post_commands": "$(printf "%s" "$post_cmd")",
  "staging_dir": "$(sanitized_abspath "$staging")",
  "toolchain_checks": $(json.dumps(toolchain_checks_arr))
}
json.dump(plan, sys.stdout, indent=2, sort_keys=True)
PY
}

# -------------------------
# validate toolchain based on array or system name
# -------------------------
validate_toolchain_arr(){
  local -n arr=$1
  local miss=()
  for t in "${arr[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then miss+=("$t"); fi
  done
  if [ "${#miss[@]}" -ne 0 ]; then
    err "Missing toolchain components: ${miss[*]}"
    return 1
  fi
  ok "Toolchain validated: ${arr[*]}"
  return 0
}

# -------------------------
# CLI and flow
# -------------------------
usage(){
  cat <<EOF
Usage:
  detect-builder.sh <build-dir|metafile>    -> detect and save build-plan JSON
  detect-builder.sh --json <build-dir|mf>   -> print JSON to stdout
  detect-builder.sh --show <plan.json>      -> pretty show plan
  detect-builder.sh --verify <plan.json>    -> verify toolchain required by plan
EOF
  exit 0
}

if [ "${#@}" -lt 1 ]; then usage; fi

case "${1:-}" in
  -h|--help) usage ;;
  --show)
    [ -n "${2:-}" ] || fatal "--show requires <plan.json>"
    if [ ! -f "$2" ]; then fatal "File not found: $2"; fi
    if [ $HAS_JQ -eq 1 ]; then jq . "$2"; else cat "$2"; fi
    exit 0
    ;;
  --verify)
    [ -n "${2:-}" ] || fatal "--verify requires <plan.json>"
    if [ ! -f "$2" ]; then fatal "File not found: $2"; fi
    sys=$(python3 - <<PY
import json,sys
print(json.load(open(sys.argv[1]))["system"])
PY "$2")
    # get toolchain_checks array if present
    mapfile -t checks < <(python3 - <<PY
import json,sys
j=json.load(open(sys.argv[1]))
print("\\n".join(j.get("toolchain_checks", [])))
PY "$2")
    if [ "${#checks[@]}" -eq 0 ]; then ok "No explicit toolchain checks in plan"; exit 0; fi
    missing=()
    for c in "${checks[@]}"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    if [ "${#missing[@]}" -ne 0 ]; then err "Missing: ${missing[*}"; exit 2; else ok "Toolchain OK"; fi
    exit 0
    ;;
  --json)
    [ -n "${2:-}" ] || fatal "--json requires <build-dir|metafile>"
    arg="$2"
    root="$(detect_build_root "$arg")"; log "Build root: ${root}"
    sys="$(detect_build_system "$root")"; ok "System: ${sys}"
    langs="$(detect_languages "$root")"; ok "Languages: ${langs}"
    special="$(detect_special_type "$root")"; ok "Special: ${special}"
    generate_build_plan "$root" "$sys" "$langs" "$special"
    exit 0
    ;;
  *)
    arg="$1"
    root="$(detect_build_root "$arg")"; log "Detected build root: ${root}"
    sys="$(detect_build_system "$root")"; ok "Detected system: ${sys}"
    langs="$(detect_languages "$root")"; ok "Detected languages: ${langs}"
    special="$(detect_special_type "$root")"; ok "Detected special type: ${special}"
    run_hooks detect pre "$arg"
    plan_json="$(generate_build_plan "$root" "$sys" "$langs" "$special")"
    name="$(basename "$root")"
    planfile="${ADM_BUILD_PLAN_DIR}/build-plan-${name}-${TIMESTAMP}.json"
    # atomic write
    printf "%s\n" "$plan_json" > "${planfile}.tmp"
    mv -f "${planfile}.tmp" "${planfile}"
    ok "Saved build-plan: ${planfile}"
    # validate toolchain from plan
    mapfile -t checks < <(python3 - <<PY
import json,sys
j=json.load(open(sys.argv[1]))
for x in j.get("toolchain_checks", []): print(x)
PY "${planfile}")
    if [ "${#checks[@]}" -gt 0 ]; then
      validate_toolchain_arr checks || { record_db "$name" "$TIMESTAMP" "$special" "$sys" fail "$planfile"; fatal "Toolchain incomplete. See ${LOGFILE} and ${planfile}"; }
    else
      ok "No explicit toolchain checks in plan"
    fi
    record_db "$name" "$TIMESTAMP" "$special" "$sys" ok "$planfile"
    run_hooks detect post "$arg"
    ok "Detection finished successfully"
    exit 0
    ;;
esac
