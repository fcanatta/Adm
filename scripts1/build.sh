#!/usr/bin/env bash
# build.sh - motor de build ADM (com múltiplos downloads/paralelo, deps topo-sort,
# extração multiformato, detecção ampla de compiladores/linguagens,
# profiles e dry-run)
#
# Salve como: /usr/src/adm/scripts/build.sh
# Uso:
#   source /usr/src/adm/scripts/env.sh  # opcional
#   source /usr/src/adm/scripts/logger.sh  # opcional
#   source /usr/src/adm/scripts/core.sh    # opcional
#   BUILD_DRY_RUN=1 ./build.sh run <categoria> <nome> [--profile normal|simple|otimizado] [--jobs N] [--deps-first]
#
set -euo pipefail
IFS=$'\n\t'

# Defaults (can be overridden by env.sh or calling environment)
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_SRC:=$ADM_ROOT/src}"
: "${ADM_VAR:=$ADM_ROOT/var}"
: "${ADM_LOG:=$ADM_VAR/log/adm.log}"
: "${BUILD_LOG_DIR:=$ADM_VAR/log/builds}"
: "${BUILD_DB:=$ADM_VAR/db/packages.list}"
: "${BUILD_TMP:=$ADM_VAR/tmp}"
: "${BUILD_CACHE:=$ADM_ROOT/var/cache}"
: "${BUILD_DRY_RUN:=${BUILD_DRY_RUN:-0}}"
: "${BUILD_JOBS:=${BUILD_JOBS:-$(nproc 2>/dev/null || echo 1)}}"
: "${BUILD_PROFILE:=${BUILD_PROFILE:-normal}}"
: "${BUILD_DOWNLOAD_CONCURRENCY:=4}"

# attempt to source env/logger/core if present (no fatal)
[ -f "${ADM_ROOT}/scripts/env.sh" ] && . "${ADM_ROOT}/scripts/env.sh" || true
[ -f "${ADM_ROOT}/scripts/logger.sh" ] && . "${ADM_ROOT}/scripts/logger.sh" || true
[ -f "${ADM_ROOT}/scripts/core.sh" ] && . "${ADM_ROOT}/scripts/core.sh" || true

# simple fallback log functions if logger.sh missing
if ! declare -f log_info >/dev/null 2>&1; then
  log_info(){ printf "[INFO] %s\n" "$*"; }
  log_warn(){ printf "[WARN] %s\n" "$*"; }
  log_error(){ printf "[ERROR] %s\n" "$*" >&2; }
  spinner_start(){ :; }
  spinner_stop(){ :; }
fi

# helpers
_mkdir() { mkdir -p "$@" 2>/dev/null || true; }
_safe_mv(){ mv -f "$1" "$2" 2>/dev/null || cp -a "$1" "$2" 2>/dev/null || true; }

# parse .meta (INI minimal)
# usage: meta_vars="$(load_meta /path/to/.meta)"; then readarray -t lines <<<"$meta_vars"
load_meta() {
  local meta="$1"
  if [ ! -f "$meta" ]; then
    log_error "meta not found: $meta"
    return 2
  fi
  # normalize keys: name, version, sourceN, sha256sumN, deps
  awk -F= '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    { gsub(/^[ \t]+|[ \t]+$/,"",$1); gsub(/^[ \t]+|[ \t]+$/,"",$2); print $1"="$2 }
  ' "$meta"
}

# read meta into arrays
read_meta_into_vars() {
  local meta="$1"
  PKG_META_PATH="$meta"
  unset PKG_NAME PKG_VERSION
  PKG_SOURCES=()
  PKG_SHA256=()
  PKG_DEPS=()
  while IFS='=' read -r k v; do
    case "${k,,}" in
      name) PKG_NAME="$v" ;;
      version) PKG_VERSION="$v" ;;
      deps) 
        # deps may be space or comma separated
        v="${v//,/ }"
        read -r -a arr <<<"$v"
        PKG_DEPS=("${PKG_DEPS[@]:-}" "${arr[@]}")
        ;;
      source*|url*)
        PKG_SOURCES+=("$v")
        ;;
      sha256sum*|sha256*)
        PKG_SHA256+=("$v")
        ;;
      *) ;;
    esac
  done < <(load_meta "$meta")
  # sanity
  if [ -z "${PKG_NAME:-}" ] || [ -z "${PKG_VERSION:-}" ]; then
    log_error "meta missing name/version: $meta"
    return 2
  fi
  return 0
}

# Topological sort for dependencies
# Input: array PKG_DEPS_REQ where each element "pkg:dep1 dep2"
# We'll implement a lightweight resolver that reads metas under /usr/src/adm/meta
# and builds order to build missing deps. For heavy graphs (gnome/xorg) this
# is heuristic: uses available metas under ADM_ROOT/meta and installed DB.
_resolve_deps_toposort() {
  local target_pkg="$1"
  local -A graph
  local -A seen
  local -a order

  # helper: load package's deps from meta dir
  _pkg_meta_deps() {
    local pkg="$1"
    local metafile
    # search for meta under ADM_ROOT/meta/*/pkg/.meta or /meta/*/pkg
    metafile="$(find "$ADM_ROOT/meta" -maxdepth 3 -type f -name "${pkg}.meta" -o -name ".meta" -path "*/${pkg}/*" 2>/dev/null | head -n1 || true)"
    if [ -z "$metafile" ]; then
      # try meta/pkgnamedir
      metafile="$(find "$ADM_ROOT/meta" -maxdepth 2 -type f -name "${pkg}.meta" 2>/dev/null | head -n1 || true)"
    fi
    if [ -z "$metafile" ]; then
      # no meta known -> return empty
      echo ""
      return
    fi
    # parse deps line
    awk -F= 'BEGIN{IGNORECASE=1} /^deps[[:space:]]*=/ { gsub(/,/," ",$2); gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit }' "$metafile" 2>/dev/null || true
  }

  # DFS
  _visit() {
    local p="$1"
    if [ "${seen[$p]:-}" = "perm" ]; then return 0; fi
    if [ "${seen[$p]:-}" = "temp" ]; then
      log_error "Dependency cycle detected at $p"
      return 2
    fi
    seen[$p]="temp"
    local deps
    deps="$(_pkg_meta_deps "$p")"
    for d in $deps; do
      _visit "$d" || return 2
    done
    seen[$p]="perm"
    order+=("$p")
    return 0
  }

  # start from target
  _visit "$target_pkg" || return 2
  # return order (dependencies first, target last)
  printf "%s\n" "${order[@]}"
  return 0
}

# check if package is installed by scanning BUILD_DB
is_installed() {
  local pkg="$1"; local ver="$2"
  if [ -f "$BUILD_DB" ]; then
    if grep -E "^${pkg}\|" "$BUILD_DB" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# download helpers (parallel)
_download_worker() {
  local idx="$1"; shift
  local url="$1"; local destdir="$2"
  local logf="$3"
  _mkdir "$destdir"
  local filename
  filename="$(basename "$url")"
  case "$url" in
    git://*|https://*/*.git|git+ssh://*|git+https://*|ssh://*|*github.com*/*.git)
      if [ "$BUILD_DRY_RUN" -eq 1 ]; then
        log_info "(dry-run) git clone $url -> $destdir/$idx"
        echo "$destdir/git-snapshot-$idx.tar.xz"
        return 0
      fi
      # perform shallow clone then archive
      tmpdir="$(mktemp -d "$BUILD_TMP/gitclone.XXXX")"
      git clone --depth 1 "$url" "$tmpdir" >>"$logf" 2>&1 || {
        log_error "git clone failed for $url"
        rm -rf "$tmpdir"
        return 1
      }
      (cd "$tmpdir" && git rev-parse --verify HEAD 2>/dev/null > "$destdir/commit-$idx" || true)
      tar -cJf "$destdir/git-snapshot-$idx.tar.xz" -C "$tmpdir" . >>"$logf" 2>&1 || true
      rm -rf "$tmpdir"
      echo "$destdir/git-snapshot-$idx.tar.xz"
      return 0
      ;;
    rsync://*|*/rsync/*)
      if [ "$BUILD_DRY_RUN" -eq 1 ]; then
        log_info "(dry-run) rsync $url -> $destdir"
        echo "$destdir/rsync-$idx"
        return 0
      fi
      if ! command -v rsync >/dev/null 2>&1; then
        log_warn "rsync not available, falling back to wget for $url"
      else
        rsync -a "$url" "$destdir" >>"$logf" 2>&1 || {
          log_error "rsync failed for $url"
          return 1
        }
        # produce a tarball of the synced content
        tar -cJf "$destdir/rsync-$idx.tar.xz" -C "$destdir" . >>"$logf" 2>&1 || true
        echo "$destdir/rsync-$idx.tar.xz"
        return 0
      fi
      ;;
    ftp://*|http://*|https://*)
      if [ "$BUILD_DRY_RUN" -eq 1 ]; then
        log_info "(dry-run) http/ftp fetch $url -> $destdir"
        echo "$destdir/$(basename "$url")"
        return 0
      fi
      _mkdir "$destdir"
      if command -v curl >/dev/null 2>&1; then
        curl -L --fail --retry 3 -o "$destdir/$(basename "$url")" "$url" >>"$logf" 2>&1 || { log_error "curl failed for $url"; return 1; }
      elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$destdir/$(basename "$url")" "$url" >>"$logf" 2>&1 || { log_error "wget failed for $url"; return 1; }
      else
        log_error "Neither curl nor wget available to fetch $url"
        return 1
      fi
      echo "$destdir/$(basename "$url")"
      return 0
      ;;
    file://*)
      local src="${url#file://}"
      if [ "$BUILD_DRY_RUN" -eq 1 ]; then
        log_info "(dry-run) cp $src -> $destdir/"
        echo "$destdir/$(basename "$src")"
        return 0
      fi
      _mkdir "$destdir"
      cp -a "$src" "$destdir/" >>"$logf" 2>&1 || { log_error "copy failed $src"; return 1; }
      echo "$destdir/$(basename "$src")"
      return 0
      ;;
    *)
      # fallback: attempt http
      if [ "$BUILD_DRY_RUN" -eq 1 ]; then
        log_info "(dry-run) fallback fetch $url -> $destdir"
        echo "$destdir/$(basename "$url")"
        return 0
      fi
      _mkdir "$destdir"
      if command -v curl >/dev/null 2>&1; then
        curl -L --fail -o "$destdir/$(basename "$url")" "$url" >>"$logf" 2>&1 || { log_error "curl fallback failed $url"; return 1; }
      elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$destdir/$(basename "$url")" "$url" >>"$logf" 2>&1 || { log_error "wget fallback failed $url"; return 1; }
      else
        log_error "No fetch method for $url"
        return 1
      fi
      echo "$destdir/$(basename "$url")"
      return 0
      ;;
  esac
}

# run multiple downloads in parallel with concurrency control
download_sources_parallel() {
  local -n urls=$1  # pass array name
  local destdir="$2"
  local logf="$3"
  _mkdir "$destdir"
  local total=${#urls[@]}
  local -a results
  local i=0
  local running=0
  local pids=()
  local tmpdir
  tmpdir="$(mktemp -d "${BUILD_TMP}/dl.XXXX")"
  trap 'rm -rf "$tmpdir" 2>/dev/null || true' RETURN INT TERM

  # semaphore using job control
  for url in "${urls[@]}"; do
    i=$((i+1))
    (
      set -e
      _download_worker "$i" "$url" "$destdir" "$logf" >/tmp/build_dl_result_"$$"_"$i".txt 2>/dev/null || echo "ERROR:$url" >/tmp/build_dl_result_"$$"_"$i".txt
    ) & pids+=($!)
    # throttle
    while [ "${#pids[@]}" -ge "$BUILD_DOWNLOAD_CONCURRENCY" ]; do
      # wait for any pid
      for idx in "${!pids[@]}"; do
        if ! kill -0 "${pids[$idx]}" 2>/dev/null; then
          wait "${pids[$idx]}" 2>/dev/null || true
          unset 'pids[idx]'
        fi
      done
      # compact
      pids=("${pids[@]}")
      sleep 0.05
    done
  done

  # wait remaining
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # collect results
  local resfile
  i=0
  for url in "${urls[@]}"; do
    i=$((i+1))
    resfile="/tmp/build_dl_result_${$}_${i}.txt"
    if [ -f "$resfile" ]; then
      read -r line <"$resfile" || line=""
      if [[ "$line" == ERROR:* ]]; then
        log_warn "download failed for ${url}: ${line#ERROR:}"
      else
        results+=("$line")
      fi
      rm -f "$resfile"
    fi
  done

  printf "%s\n" "${results[@]}"
  return 0
}

# checksum verify
verify_sha256() {
  local file="$1"; local expected="$2"
  if [ -z "$expected" ]; then
    return 0
  fi
  if [ "$BUILD_DRY_RUN" -eq 1 ]; then
    log_info "(dry-run) would verify sha256 $file"
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    local found
    found="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')"
    if [ "$found" != "$expected" ]; then
      log_error "sha256 mismatch for $file (got $found expected $expected)"
      return 2
    fi
    return 0
  elif command -v shasum >/dev/null 2>&1; then
    local found
    found="$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}')"
    if [ "$found" != "$expected" ]; then
      log_error "sha256 mismatch for $file (got $found expected $expected)"
      return 2
    fi
    return 0
  else
    log_warn "No sha256 tool available to verify $file"
    return 0
  fi
}

# extractor supporting many formats
extract_archive() {
  local archive="$1"
  local dest="$2"
  _mkdir "$dest"
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$dest" ;;
    *.tar.bz2|*.tbz2) tar -xjf "$archive" -C "$dest" ;;
    *.tar.xz|*.txz) tar -xJf "$archive" -C "$dest" ;;
    *.tar.zst|*.tzst) 
      if command -v zstd >/dev/null 2>&1; then
        zstd -d -c "$archive" | tar -xf - -C "$dest"
      else
        tar -xf "$archive" -C "$dest" || return 2
      fi
      ;;
    *.tar) tar -xf "$archive" -C "$dest" ;;
    *.zip) unzip -q "$archive" -d "$dest" ;;
    *.7z)
      if command -v 7z >/dev/null 2>&1; then
        7z x "$archive" -o"$dest" >/dev/null
      else
        log_error "7z not available to extract $archive"
        return 2
      fi
      ;;
    *.gz)
      if command -v gunzip >/dev/null 2>&1; then
        gunzip -c "$archive" >"$dest/$(basename "${archive%.*}")"
      else
        log_error "gunzip missing for $archive"
        return 2
      fi
      ;;
    *)
      # if directory or special file, try cp
      if [ -d "$archive" ]; then
        cp -a "$archive/." "$dest/"
      else
        log_warn "Unknown archive format: $archive; attempting tar -xf"
        tar -xf "$archive" -C "$dest" 2>/dev/null || { log_error "failed to extract $archive"; return 2; }
      fi
      ;;
  esac
  return 0
}

# detection of build system and languages/compilers
detect_build_system_and_compilers() {
  local srcdir="$1"
  BUILD_SYSTEM="unknown"
  BUILD_CONFIG_CMD=""
  BUILD_COMPILE_CMD=""
  BUILD_INSTALL_CMD=""
  PKG_CC="" PKG_CXX="" PKG_FC=""
  # detect files
  if [ -f "$srcdir/configure" ]; then
    BUILD_SYSTEM="autotools"
    BUILD_CONFIG_CMD="./configure --prefix=/usr"
    BUILD_COMPILE_CMD="make -j${BUILD_JOBS}"
    BUILD_INSTALL_CMD="make install DESTDIR=%STAGING%"
  elif [ -f "$srcdir/CMakeLists.txt" ]; then
    BUILD_SYSTEM="cmake"
    BUILD_CONFIG_CMD="cmake -S \"$srcdir\" -B \"$srcdir/build\" -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release"
    BUILD_COMPILE_CMD="cmake --build \"$srcdir/build\" -- -j${BUILD_JOBS}"
    BUILD_INSTALL_CMD="cmake --install \"$srcdir/build\" --prefix=/usr --strip --skip-build"
  elif [ -f "$srcdir/meson.build" ]; then
    BUILD_SYSTEM="meson"
    BUILD_CONFIG_CMD="meson setup \"$srcdir/build\" \"$srcdir\" --prefix=/usr"
    BUILD_COMPILE_CMD="meson compile -C \"$srcdir/build\" -j ${BUILD_JOBS}"
    BUILD_INSTALL_CMD="meson install -C \"$srcdir/build\" --destdir=%STAGING%"
  elif [ -f "$srcdir/setup.py" ] || [ -f "$srcdir/pyproject.toml" ]; then
    BUILD_SYSTEM="python"
    BUILD_CONFIG_CMD=""
    BUILD_COMPILE_CMD="python3 -m pip wheel . -w build-wheel"
    BUILD_INSTALL_CMD="python3 -m pip install --prefix=/usr --root=%STAGING% ."
  elif [ -f "$srcdir/Cargo.toml" ]; then
    BUILD_SYSTEM="cargo"
    BUILD_CONFIG_CMD=""
    BUILD_COMPILE_CMD="cargo build --release -j ${BUILD_JOBS}"
    BUILD_INSTALL_CMD="cargo install --path . --root %STAGING%"
  elif [ -f "$srcdir/go.mod" ]; then
    BUILD_SYSTEM="go"
    BUILD_CONFIG_CMD=""
    BUILD_COMPILE_CMD="go build ./..."
    BUILD_INSTALL_CMD="mkdir -p %STAGING%/usr/bin && cp -a $(find . -type f -perm -111 -maxdepth 2) %STAGING%/usr/bin || true"
  elif [ -f "$srcdir/Makefile" ]; then
    BUILD_SYSTEM="make"
    BUILD_CONFIG_CMD=""
    BUILD_COMPILE_CMD="make -j${BUILD_JOBS}"
    BUILD_INSTALL_CMD="make install DESTDIR=%STAGING%"
  else
    # try to detect common languages
    if grep -qE '^\s*cmake_minimum_required' "$srcdir"/* 2>/dev/null; then
      BUILD_SYSTEM="cmake"
      BUILD_CONFIG_CMD="cmake -S \"$srcdir\" -B \"$srcdir/build\" -DCMAKE_INSTALL_PREFIX=/usr"
      BUILD_COMPILE_CMD="cmake --build \"$srcdir/build\" -- -j${BUILD_JOBS}"
      BUILD_INSTALL_CMD="cmake --install \"$srcdir/build\" --prefix=/usr --strip --skip-build"
    fi
  fi

  # detect compilers available and pick preferred
  PKG_CC=""
  PKG_CXX=""
  # prefer clang if set in profile? use env BUILD_PROFILE to influence (otimizado prefer gcc/clang)
  if command -v gcc >/dev/null 2>&1; then PKG_CC=$(command -v gcc); fi
  if command -v clang >/dev/null 2>&1; then
    # prefer clang if available and profile otimizado
    if [ "${BUILD_PROFILE}" = "otimizado" ]; then PKG_CC=$(command -v clang); fi
    PKG_CC=${PKG_CC:-$(command -v clang)}
  fi
  if command -v cc >/dev/null 2>&1 && [ -z "$PKG_CC" ]; then PKG_CC=$(command -v cc); fi
  if command -v g++ >/dev/null 2>&1; then PKG_CXX=$(command -v g++); fi
  if command -v clang++ >/dev/null 2>&1; then PKG_CXX=$(command -v clang++); fi
  # Fortran
  if command -v gfortran >/dev/null 2>&1; then PKG_FC=$(command -v gfortran); fi

  # produce env vars string for configure
  local ccenv=""
  [ -n "$PKG_CC" ] && ccenv+="CC=\"$PKG_CC\" "
  [ -n "$PKG_CXX" ] && ccenv+="CXX=\"$PKG_CXX\" "
  [ -n "$PKG_FC" ] && ccenv+="FC=\"$PKG_FC\" "

  BUILD_CC_ENV="$ccenv"
  return 0
}

# build a single package from meta path
build_run_from_meta() {
  local meta_path="$1"
  local opt_deps_first="${2:-0}"
  local profile="${3:-$BUILD_PROFILE}"
  local jobs="${4:-$BUILD_JOBS}"

  read_meta_into_vars "$meta_path" || return 2
  local catdir pkgdir
  pkgdir="$PKG_NAME-$PKG_VERSION"
  catdir="$(dirname "$meta_path")"
  # prepare logs and staging
  local logf="$BUILD_LOG_DIR/${PKG_NAME}-${PKG_VERSION}.log"
  _mkdir "$BUILD_LOG_DIR"
  _mkdir "$BUILD_TMP"
  local staging="$BUILD_TMP/staging-${PKG_NAME}-${PKG_VERSION}"
  rm -rf "$staging"
  _mkdir "$staging"

  log_info "Preparing build for ${PKG_NAME}@${PKG_VERSION}"
  log_info "Meta: $meta_path"

  # deps
  if [ "${opt_deps_first}" = "1" ] && [ "${#PKG_DEPS[@]}" -gt 0 ]; then
    log_info "Resolving dependencies for ${PKG_NAME}"
    # naive: use topo resolver for target pkg name
    IFS=$'\n' read -r -d '' -a deporder < <(_resolve_deps_toposort "$PKG_NAME" 2>/dev/null | tr '\n' '\0') || true
    for dep in "${deporder[@]}"; do
      [ -z "$dep" ] && continue
      if is_installed "$dep"; then
        log_info "dep $dep already installed"
        continue
      fi
      # try to find meta for dep
      local depmeta
      depmeta="$(find "$ADM_ROOT/meta" -type f -name "${dep}.meta" -print -quit 2>/dev/null || true)"
      if [ -n "$depmeta" ]; then
        log_info "Building dependency $dep from meta $depmeta"
        build_run_from_meta "$depmeta" 1 "$profile" "$jobs" || { log_error "Failed building dependency $dep"; return 2; }
      else
        log_warn "No meta found for dependency $dep; you may need to provide it"
      fi
    done
  fi

  # download all PKG_SOURCES in parallel
  log_info "Downloading ${#PKG_SOURCES[@]} source(s) for ${PKG_NAME}"
  local dl_dest="$ADM_SRC/$PKG_NAME/$PKG_VERSION"
  _mkdir "$dl_dest"
  local -a urls
  urls=("${PKG_SOURCES[@]}")
  # run downloads
  local dl_results
  mapfile -t dl_results < <(download_sources_parallel urls "$dl_dest" "$logf")
  if [ "${#dl_results[@]}" -eq 0 ]; then
    log_warn "No downloaded artifacts for ${PKG_NAME}; continuing if local sources present"
  fi

  # verify checksums if provided; tries pairwise mapping by index
  for i in "${!dl_results[@]}"; do
    local file="${dl_results[$i]}"
    local expected="${PKG_SHA256[$i]:-}"
    if [ -n "$file" ] && [ -f "$file" ]; then
      verify_sha256 "$file" "$expected" || { log_error "Checksum failed for $file"; return 2; }
    fi
  done

  # locate an archive or source dir to extract
  local src_extract_dir="$BUILD_TMP/src-${PKG_NAME}-${PKG_VERSION}"
  rm -rf "$src_extract_dir"
  _mkdir "$src_extract_dir"
  local chosen=""
  # prefer tarballs produced by git snapshot if present
  for f in "${dl_results[@]}"; do
    [ -z "$f" ] && continue
    if [ -f "$f" ]; then
      chosen="$f"
      break
    fi
  done
  # If no files but there is local meta dir with files
  if [ -z "$chosen" ]; then
    if [ -d "$catdir" ]; then
      chosen="$catdir"
    fi
  fi

  if [ -z "$chosen" ]; then
    log_error "No source found for ${PKG_NAME}"
    return 2
  fi

  # extract chosen
  log_info "Extracting source $chosen -> $src_extract_dir"
  if [ -d "$chosen" ]; then
    # copy folder
    cp -a "$chosen/." "$src_extract_dir/" 2>/dev/null || true
  else
    extract_archive "$chosen" "$src_extract_dir" || { log_error "Extraction failed for $chosen"; return 2; }
  fi

  # find top-level source dir (common single subdir)
  local topdir
  topdir="$(find "$src_extract_dir" -maxdepth 2 -mindepth 1 -type d -printf '%P\n' | head -n1 || true)"
  # if extraction produced many files directly, use $src_extract_dir
  local build_src_dir="$src_extract_dir"
  if [ -n "$topdir" ]; then
    # if topdir is ., keep
    if [ "$topdir" != "." ]; then
      build_src_dir="$src_extract_dir/$topdir"
    fi
  fi
  log_info "Source prepared in $build_src_dir"

  # detect build system and compilers
  detect_build_system_and_compilers "$build_src_dir"
  log_info "Detected build system: $BUILD_SYSTEM"
  log_info "Compiler env: $BUILD_CC_ENV"

  # prepare environment vars and flags based on profile
  local cflags="" ldflags="" extra_env=""
  case "$profile" in
    simple)
      cflags="-O1 -g"
      ;;
    normal)
      cflags="-O2 -pipe -fstack-protector-strong"
      ;;
    otimizado|optimized)
      cflags="-O3 -flto -march=native -pipe"
      ldflags="-flto"
      ;;
    *) cflags="-O2 -pipe";;
  esac
  extra_env="$BUILD_CC_ENV CFLAGS=\"$cflags\" LDFLAGS=\"$ldflags\" MAKEFLAGS=\"-j${jobs}\""

  # run configure/build/install using core_exec_step to get rollback and spinner
  local cfg_cmd compile_cmd inst_cmd
  cfg_cmd="${BUILD_CONFIG_CMD//%STAGING%/$staging}"
  compile_cmd="${BUILD_COMPILE_CMD//%STAGING%/$staging}"
  inst_cmd="${BUILD_INSTALL_CMD//%STAGING%/$staging}"

  # pre-build hooks if present under meta/patch or meta/hooks
  local hookdir
  hookdir="$(dirname "$meta_path")/hooks"
  if [ -d "$hookdir" ]; then
    for hook in "$hookdir"/pre-build*; do
      [ -f "$hook" ] || continue
      core_exec_step "pre-build-hook: $(basename "$hook")" "bash \"$hook\" \"$PKG_NAME\" \"$PKG_VERSION\" \"$build_src_dir\"" || {
        log_warn "pre-build hook $(basename "$hook") failed"
      }
    done
  fi

  # run configure if present
  if [ -n "$cfg_cmd" ]; then
    core_exec_step "Configuring ${PKG_NAME}" "cd \"$build_src_dir\" && eval $extra_env $cfg_cmd" || return 2
  fi

  # compile
  if [ -n "$compile_cmd" ]; then
    core_exec_step "Compiling ${PKG_NAME}" "cd \"$build_src_dir\" && eval $extra_env $compile_cmd" || return 2
  fi

  # install into staging dir
  core_exec_step "Installing ${PKG_NAME} into staging" "mkdir -p \"$staging\" && cd \"$build_src_dir\" && eval $extra_env $inst_cmd" || return 2

  # post-build hooks
  if [ -d "$hookdir" ]; then
    for hook in "$hookdir"/post-build*; do
      [ -f "$hook" ] || continue
      core_exec_step "post-build-hook: $(basename "$hook")" "bash \"$hook\" \"$PKG_NAME\" \"$PKG_VERSION\" \"$staging\"" || {
        log_warn "post-build hook $(basename "$hook") failed"
      }
    done
  fi

  # package staging -> tar.zst (prefer zstd)
  _mkdir "$BUILD_CACHE/$PKG_NAME"
  local pkgfile="$BUILD_CACHE/$PKG_NAME/${PKG_NAME}-${PKG_VERSION}.pkg.tar"
  if command -v zstd >/dev/null 2>&1; then
    pkgfile="${pkgfile}.zst"
    core_exec_step "Packing ${PKG_NAME}" "tar -C \"$staging\" -cf - . | zstd -q -o \"$pkgfile\"" || return 2
  elif command -v xz >/dev/null 2>&1; then
    pkgfile="${pkgfile}.xz"
    core_exec_step "Packing ${PKG_NAME}" "tar -C \"$staging\" -cf - . | xz -z -c > \"$pkgfile\"" || return 2
  else
    pkgfile="${pkgfile}.tar"
    core_exec_step "Packing ${PKG_NAME}" "tar -C \"$staging\" -cf \"$pkgfile\" ." || return 2
  fi

  # register package (append simple CSV)
  _mkdir "$(dirname "$BUILD_DB")"
  local now ts
  ts="$(_core_now 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "${PKG_NAME}|${PKG_VERSION}|${ts}|${pkgfile}" >>"$BUILD_DB"
  log_info "Registered package ${PKG_NAME}@${PKG_VERSION} -> $pkgfile"

  # generate update/.meta for this build
  local meta_dir="$ADM_ROOT/update/$(basename "$catdir")/$PKG_NAME"
  _mkdir "$meta_dir"
  cat >"$meta_dir/.meta" <<EOF
name=${PKG_NAME}
version=${PKG_VERSION}
sources=${PKG_SOURCES[*]}
sha256sum=${PKG_SHA256[*]}
deps=${PKG_DEPS[*]}
built_at=${ts}
package=${pkgfile}
EOF

  # cleanup staging (leave cache and logs)
  # default: remove staging, keep BUILD_TMP/src-*
  rm -rf "$staging"
  log_info "Build completed: ${PKG_NAME}@${PKG_VERSION}"
  return 0
}

# top-level dispatcher
_main_usage() {
  cat <<EOF
build.sh - ADM build driver
Usage:
  build.sh run <category> <pkgname> [--profile PROFILE] [--jobs N] [--deps-first] [--meta /path/to/meta]
  build.sh meta2vars /path/to/.meta  (debug)
  env variable BUILD_DRY_RUN=1 to perform dry-run
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="$1"
  shift || true
  case "$cmd" in
    run)
      category="$1"; pkgname="$2"; shift 2 || true
      profile="$BUILD_PROFILE"; jobs="$BUILD_JOBS"; deps_first=0; meta_path=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --profile) profile="$2"; shift 2;;
          --jobs) jobs="$2"; shift 2;;
          --deps-first) deps_first=1; shift;;
          --meta) meta_path="$2"; shift 2;;
          --dry-run) BUILD_DRY_RUN=1; shift;;
          *) shift;;
        esac
      done
      if [ -z "$meta_path" ]; then
        # try to locate meta at ADM_ROOT/meta/<category>/<pkgname>/.meta or ADM_ROOT/meta/<category>/<pkgname>.meta
        if [ -f "$ADM_ROOT/meta/$category/$pkgname/.meta" ]; then
          meta_path="$ADM_ROOT/meta/$category/$pkgname/.meta"
        elif [ -f "$ADM_ROOT/meta/$category/$pkgname.meta" ]; then
          meta_path="$ADM_ROOT/meta/$category/$pkgname.meta"
        fi
      fi
      if [ -z "$meta_path" ]; then
        log_error "Meta not provided and not found for $category/$pkgname"
        exit 2
      fi
      build_run_from_meta "$meta_path" "$deps_first" "$profile" "$jobs" || exit 1
      ;;
    meta2vars)
      read_meta_into_vars "$1"
      declare -p PKG_NAME PKG_VERSION PKG_SOURCES PKG_SHA256 PKG_DEPS || true
      ;;
    help|-h|--help|*)
      _main_usage
      ;;
  esac
fi
