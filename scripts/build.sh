#!/usr/bin/env bash
# /usr/src/adm/scripts/build.sh
# ADM Build System - build.sh
# Version: 1.0
# Purpose: detect build method, support MODE=custom, run full build lifecycle
set -o errexit
set -o nounset
set -o pipefail

# -------------------------
# Defaults & environment
# -------------------------
ADM_BASE="${ADM_BASE:-/usr/src/adm}"
ADM_SCRIPTS="${ADM_SCRIPTS:-${ADM_BASE}/scripts}"
ADM_REPO="${ADM_REPO:-${ADM_BASE}/repo}"
ADM_LOGS="${ADM_LOGS:-${ADM_BASE}/logs}"
ADM_DB="${ADM_DB:-${ADM_BASE}/db}"
ADM_TMP="${ADM_TMP:-${ADM_BASE}/tmp}"
TS="$(date '+%Y%m%d_%H%M%S')"

# CLI defaults
PKG_NAME=""
FORCE_REBUILD=0
STRICT=0
DRY_RUN=0
DEBUG=0
AUTO_YES=0
KEEP_BUILD_DIR=0
RESUME=0
METHOD_OVERRIDE=""
VERBOSE=0

# runtime
BUILD_DIR=""
PKG_LOG=""
PKG_DIR=""
PKG_CONF=""
PKG_VERSION="unknown"
PKG_SOURCE=""
PKG_DESC=""
PKG_DEPENDS=""
MODE="auto"            # auto|custom|manual
BUILD_METHOD=""        # detected method: autotools, cmake, meson, python, rust, go, node, make, zig, gradle, scons, qmake, manual, custom
START_TS=0
END_TS=0

# create base dirs
mkdir -p "${ADM_LOGS}" "${ADM_DB}" "${ADM_TMP}" 2>/dev/null || true

# Try to source helpers (non-fatal)
if [[ -r "${ADM_SCRIPTS}/env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_SCRIPTS}/env.sh" || true
fi
_UI=0; _LOG=0
if [[ -r "${ADM_SCRIPTS}/log.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_SCRIPTS}/log.sh" || true
  _LOG=1
fi
if [[ -r "${ADM_SCRIPTS}/ui.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_SCRIPTS}/ui.sh" || true
  _UI=1
fi

# -------------------------
# Logging wrappers (fallback)
# -------------------------
_now() { date '+%Y-%m-%d %H:%M:%S'; }

LOGFILE_GLOBAL="${ADM_LOGS}/build-global-${TS}.log"

log_write() {
  local lvl="$1"; shift
  local msg="$*"
  printf "%s [%s] %s\n" "$(_now)" "$lvl" "$msg" >>"${LOGFILE_GLOBAL}"
  if [[ "${_LOG}" -eq 1 ]]; then
    case "$lvl" in
      INFO) if type -t log_info >/dev/null 2>&1; then log_info "$msg"; fi ;;
      WARN) if type -t log_warn >/dev/null 2>&1; then log_warn "$msg"; fi ;;
      ERROR) if type -t log_error >/dev/null 2>&1; then log_error "$msg"; fi ;;
    esac
  else
    if [[ "${VERBOSE}" -eq 1 ]]; then
      printf "[%s] %s\n" "$lvl" "$msg"
    fi
  fi
}
log_info(){ log_write INFO "$*"; }
log_warn(){ log_write WARN "$*"; }
log_error(){ log_write ERROR "$*"; }

# pkg log per package
pkg_log_init() {
  PKG_LOG="${ADM_LOGS}/build-${PKG_NAME}-${TS}.log"
  touch "${PKG_LOG}" 2>/dev/null || true
}

pkg_log() {
  local lvl="$1"; shift
  printf "%s [%s] %s\n" "$(_now)" "$lvl" "$*" >>"${PKG_LOG}"
}

# UI wrappers
ui_start_section() {
  local title="$1"
  if [[ "${_UI}" -eq 1 && "$(type -t ui_section 2>/dev/null)" == "function" ]]; then
    ui_section "$title"
  else
    printf "[  ] %s\n" "$title"
  fi
}
ui_end_ok() {
  local title="$1"
  if [[ "${_UI}" -eq 1 && "$(type -t ui_end_section 2>/dev/null)" == "function" ]]; then
    ui_end_section 0 "$title"
  else
    printf "[✔️] %s... concluído\n" "$title"
  fi
}
ui_end_fail() {
  local title="$1"
  if [[ "${_UI}" -eq 1 && "$(type -t ui_end_section 2>/dev/null)" == "function" ]]; then
    ui_end_section 1 "$title"
  else
    printf "[✖] %s... falhou\n" "$title"
  fi
}
ui_info() {
  if [[ "${_UI}" -eq 1 && "$(type -t ui_info 2>/dev/null)" == "function" ]]; then
    ui_info "$*"
  else
    printf "[i] %s\n" "$*"
  fi
}

# -------------------------
# Utility functions
# -------------------------
safe_mkdir() { mkdir -p "$1"; chmod 0755 "$1" 2>/dev/null || true; }
confirm() {
  if [[ "${AUTO_YES}" -eq 1 ]]; then return 0; fi
  printf "%s [y/N]: " "$1"
  read -r ans
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

# find package dir
pkg_dir_from_name() {
  local name="$1"
  if [[ -d "${ADM_REPO}/${name}" ]]; then
    printf "%s\n" "$(readlink -f "${ADM_REPO}/${name}")"
    return 0
  fi
  local found
  found="$(find "${ADM_REPO}" -maxdepth 4 -type d -name "${name}" -print -quit 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    printf "%s\n" "$(readlink -f "$found")"
    return 0
  fi
  return 2
}

# read build.conf key safely
read_build_key() {
  local conf="$1" key="$2"
  if [[ ! -r "$conf" ]]; then
    return 1
  fi
  awk -F= -v k="$key" '
    $0 ~ "^"k"=" {
      $1=""; sub(/^=/,"",$0);
      val=$0; gsub(/^[[:space:]]*/,"",val); gsub(/[[:space:]]*$/,"",val);
      gsub(/^"|"$/,"",val); gsub(/^'\''|'\''$/,"",val);
      print val; exit
    }' "$conf" || true
}

# source build.conf safely (for custom_build) into isolated env
source_build_conf_safe() {
  local conf="$1"
  # create a subshell file to source but prevent execution of arbitrary commands at top-level:
  # strategy: source conf inside a subshell and extract function definitions only
  # We'll capture function body of custom_build if present using awk
  if [[ ! -r "$conf" ]]; then return 1; fi
  awk '/^custom_build[[:space:]]*\(\)[[:space:]]*\{/{flag=1; print; next}
       flag{print}
       /^}/{ if(flag){ print; exit } }' "$conf" > "${ADM_TMP}/build-conf-custom-${PKG_NAME}.sh" 2>/dev/null || true
  # file may contain only function or be empty
  if [[ -s "${ADM_TMP}/build-conf-custom-${PKG_NAME}.sh" ]]; then
    # source it in current shell to define custom_build, but we will guard it by MODE check
    # Use a subshell execution to validate syntax first:
    if bash -n "${ADM_TMP}/build-conf-custom-${PKG_NAME}.sh" 2>/dev/null; then
      # source into current shell (function will be defined)
      # ensure no other commands execute by only generating function file
      # shellcheck disable=SC1090
      source "${ADM_TMP}/build-conf-custom-${PKG_NAME}.sh" || true
      return 0
    else
      log_warn "custom_build function syntax error in ${conf}"
      return 2
    fi
  fi
  return 3
}

# ensure cleanup on exit
on_exit() {
  local rc=$?
  # if build dir exists and not keep, cleanup may be handled in build_cleanup
  if [[ $rc -ne 0 ]]; then
    log_error "build.sh: encerrando com código $rc"
    ui_end_fail "build (erro)"
  fi
  # remove lock if present
  if [[ -f "${ADM_TMP}/build-${PKG_NAME}.lock" ]]; then
    rm -f "${ADM_TMP}/build-${PKG_NAME}.lock" 2>/dev/null || true
  fi
}
trap on_exit EXIT

# -------------------------
# Core: load package config
# -------------------------
build_load_conf() {
  local input="$1"
  if [[ -z "$input" ]]; then
    log_error "build_load_conf: package name required"
    return 2
  fi
  PKG_NAME="$input"
  # find package dir
  if ! PKG_DIR="$(pkg_dir_from_name "${PKG_NAME}")"; then
    log_error "Pacote não encontrado em repo: ${PKG_NAME}"
    return 2
  fi
  PKG_CONF="${PKG_DIR}/build.conf"
  if [[ ! -r "${PKG_CONF}" ]]; then
    log_error "build.conf ausente para ${PKG_NAME} (${PKG_CONF})"
    return 2
  fi
  # read keys
  PKG_VERSION="$(read_build_key "${PKG_CONF}" "VERSION" || echo "unknown")"
  PKG_SOURCE="$(read_build_key "${PKG_CONF}" "SOURCE" || echo "")"
  PKG_DESC="$(read_build_key "${PKG_CONF}" "DESC" || echo "")"
  PKG_DEPENDS="$(read_build_key "${PKG_CONF}" "DEPEND" || echo "")"
  MODE_RAW="$(read_build_key "${PKG_CONF}" "MODE" || echo "auto")"
  MODE="${MODE_RAW:-auto}"
  if [[ -z "${PKG_VERSION:-}" ]]; then PKG_VERSION="unknown"; fi
  pkg_log_init
  pkg_log INFO "Loaded build.conf for ${PKG_NAME} (version=${PKG_VERSION}, mode=${MODE})"
  return 0
}

# -------------------------
# build_prepare: fetch, extract, chdir
# -------------------------
build_prepare() {
  ui_start_section "Preparando ambiente de build para ${PKG_NAME}"
  # create lock
  safe_mkdir "${ADM_TMP}"
  touch "${ADM_TMP}/build-${PKG_NAME}.lock"
  START_TS="$(date +%s)"
  # build dir
  BUILD_DIR="${ADM_TMP}/build-${PKG_NAME}-${TS}"
  if [[ "${RESUME}" -eq 1 ]]; then
    # try to detect previous build dir pattern
    local prev
    prev="$(ls -d ${ADM_TMP}/build-${PKG_NAME}-* 2>/dev/null | sort -r | head -n1 || true)"
    if [[ -n "$prev" && -d "$prev" ]]; then
      BUILD_DIR="$prev"
      pkg_log INFO "Resuming build in ${BUILD_DIR}"
    fi
  fi
  if [[ "${KEEP_BUILD_DIR}" -eq 0 && -d "${BUILD_DIR}" ]]; then
    rm -rf "${BUILD_DIR}" || true
  fi
  mkdir -p "${BUILD_DIR}" || { pkg_log ERROR "Falha ao criar ${BUILD_DIR}"; return 2; }
  pkg_log INFO "Build dir: ${BUILD_DIR}"

  # Ensure dependencies are resolved (call deps.sh)
  if [[ -x "${ADM_SCRIPTS}/deps.sh" ]]; then
    pkg_log INFO "Chamando deps.sh para ${PKG_NAME}"
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      if ! "${ADM_SCRIPTS}/deps.sh" --pkg "${PKG_NAME}" --resolve >>"${PKG_LOG}" 2>&1; then
        pkg_log WARN "deps.sh reportou problemas (ver ${PKG_LOG})"
        if [[ "${STRICT}" -eq 1 ]]; then
          ui_end_fail "Deps"
          return 3
        fi
      fi
    else
      pkg_log INFO "DRY-RUN: pulando execução de deps.sh"
    fi
  else
    pkg_log WARN "deps.sh ausente: assumindo dependências já resolvidas"
  fi

  # fetch source via fetch.sh
  if [[ -x "${ADM_SCRIPTS}/fetch.sh" ]]; then
    pkg_log INFO "Chamando fetch.sh"
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      if ! "${ADM_SCRIPTS}/fetch.sh" --pkg "${PKG_NAME}" >>"${PKG_LOG}" 2>&1; then
        pkg_log ERROR "fetch.sh falhou para ${PKG_NAME}"
        if [[ "${STRICT}" -eq 1 ]]; then ui_end_fail "Fetch"; return 4; fi
      fi
    else
      pkg_log INFO "DRY-RUN: pulando fetch.sh"
    fi
  else
    pkg_log WARN "fetch.sh não encontrado; esperando fonte já presente em cache"
  fi

  # extract source: look for archives in repo/cache or source path
  # If PKG_SOURCE is a URL, fetch.sh should have placed it in cache; otherwise try to find a source tarball
  local src_candidate
  src_candidate="$(find "${ADM_REPO}/${PKG_NAME}" -maxdepth 2 -type f -name "${PKG_NAME}*.tar.*" -o -name "${PKG_NAME}*.zip" -print -quit 2>/dev/null || true)"
  if [[ -n "${src_candidate}" ]]; then
    pkg_log INFO "Found source archive: ${src_candidate}"
    # extract heuristics
    case "${src_candidate}" in
      *.tar.gz|*.tgz) tar -xzf "${src_candidate}" -C "${BUILD_DIR}" >>"${PKG_LOG}" 2>&1 || true ;;
      *.tar.xz) tar -xJf "${src_candidate}" -C "${BUILD_DIR}" >>"${PKG_LOG}" 2>&1 || true ;;
      *.tar.bz2) tar -xjf "${src_candidate}" -C "${BUILD_DIR}" >>"${PKG_LOG}" 2>&1 || true ;;
      *.zip) unzip -q "${src_candidate}" -d "${BUILD_DIR}" >>"${PKG_LOG}" 2>&1 || true ;;
      *) cp -a "${src_candidate}" "${BUILD_DIR}/" >>"${PKG_LOG}" 2>&1 || true ;;
    esac
  else
    # try if PKG_SOURCE is local file path
    if [[ -f "${PKG_SOURCE}" ]]; then
      pkg_log INFO "Using PKG_SOURCE local file ${PKG_SOURCE}"
      case "${PKG_SOURCE}" in
        *.tar.gz|*.tgz) tar -xzf "${PKG_SOURCE}" -C "${BUILD_DIR}" >>"${PKG_LOG}" 2>&1 || true ;;
        *.tar.xz) tar -xJf "${PKG_SOURCE}" -C "${BUILD_DIR}" >>"${PKG_LOG}" 2>&1 || true ;;
        *.zip) unzip -q "${PKG_SOURCE}" -d "${BUILD_DIR}" >>"${PKG_LOG}" 2>&1 || true ;;
        *) cp -a "${PKG_SOURCE}" "${BUILD_DIR}/" >>"${PKG_LOG}" 2>&1 || true ;;
      esac
    else
      pkg_log WARN "Nenhum arquivo fonte encontrado automaticamente para ${PKG_NAME}"
      # if build.conf provides a source dir inside repo, try that
      if [[ -d "${PKG_DIR}/source" ]]; then
        pkg_log INFO "Usando diretório ${PKG_DIR}/source como fonte"
        cp -a "${PKG_DIR}/source/." "${BUILD_DIR}/" >>"${PKG_LOG}" 2>&1 || true
      fi
    fi
  fi

  # if extraction created a single top-level dir, cd into it
  local topdir
  topdir="$(find "${BUILD_DIR}" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)"
  if [[ -n "${topdir}" ]]; then
    BUILD_DIR="${topdir}"
    pkg_log INFO "Usando top-level dir: ${BUILD_DIR}"
  fi

  ui_end_ok "Preparação"
  return 0
}
# detect build method (com suporte MODE=custom)
build_detect_method() {
  ui_start_section "Detectando método de build para ${PKG_NAME}"
  pkg_log INFO "Detecting build method (MODE=${MODE}, override=${METHOD_OVERRIDE})"

  # if method override passed via CLI, use it
  if [[ -n "${METHOD_OVERRIDE}" ]]; then
    BUILD_METHOD="${METHOD_OVERRIDE}"
    pkg_log INFO "Método forçado via CLI: ${BUILD_METHOD}"
    ui_end_ok "Detecção"
    return 0
  fi

  # if build.conf contains a custom_build() function, capture it
  local conf="${PKG_CONF}"
  local custom_loaded=1
  if source_build_conf_safe "${conf}"; then
    # custom_build function now defined in shell if present
    if declare -F custom_build >/dev/null 2>&1; then
      custom_loaded=0
      pkg_log INFO "custom_build() detectada em ${conf}"
    else
      custom_loaded=1
    fi
  else
    # source_build_conf_safe returns nonzero if nothing or syntax error
    custom_loaded=1
  fi

  # If MODE is explicitly custom, ensure custom_build exists and use it
  if [[ "${MODE}" == "custom" ]]; then
    if declare -F custom_build >/dev/null 2>&1; then
      BUILD_METHOD="custom"
      pkg_log INFO "Usando modo custom (função custom_build encontrada)"
      ui_end_ok "Detecção"
      return 0
    else
      pkg_log ERROR "MODE=custom definido, mas custom_build() não encontrada ou inválida in ${conf}"
      ui_end_fail "Detecção"
      return 2
    fi
  fi

  # If MODE is not custom and custom_build exists, hide it to avoid accidental execution
  if [[ "${MODE}" != "custom" && declare -F custom_build >/dev/null 2>&1 ]]; then
    unset -f custom_build || true
    pkg_log INFO "custom_build() removida (modo automático detectado)"
  fi

  # automatic detection: check for many build system markers in BUILD_DIR
  # prefer higher-level build systems first
  local d="${BUILD_DIR}"
  BUILD_METHOD="manual"  # default fallback

  # helper to test file presence robustly
  has_file() { [[ -f "$1" || -f "${d}/$1" ]]; }

  # check presence of various files (order of precedence)
  if has_file "configure" || has_file "configure.ac" || has_file "configure.in"; then
    BUILD_METHOD="autotools"
  elif has_file "CMakeLists.txt" || has_file "cmake/presets.json" || has_file "CMakePresets.json"; then
    BUILD_METHOD="cmake"
  elif has_file "meson.build"; then
    BUILD_METHOD="meson"
  elif has_file "Cargo.toml"; then
    BUILD_METHOD="rust"
  elif has_file "setup.py" || has_file "pyproject.toml"; then
    BUILD_METHOD="python"
  elif has_file "go.mod"; then
    BUILD_METHOD="golang"
  elif has_file "package.json"; then
    BUILD_METHOD="node"
  elif has_file "build.zig"; then
    BUILD_METHOD="zig"
  elif has_file "build.gradle" || has_file "gradlew"; then
    BUILD_METHOD="gradle"
  elif has_file "SConstruct"; then
    BUILD_METHOD="scons"
  elif has_file "*.pro" || has_file "project.pro" || find "${d}" -maxdepth 1 -name '*.pro' -print -quit 2>/dev/null | grep -q .; then
    BUILD_METHOD="qmake"
  elif has_file "Makefile" || has_file "makefile"; then
    BUILD_METHOD="make"
  else
    BUILD_METHOD="manual"
  fi

  pkg_log INFO "Método detectado: ${BUILD_METHOD}"
  ui_end_ok "Detecção"
  return 0
}

# helper to run shell commands in BUILD_DIR, log output, return rc
run_in_build() {
  local cmd="$*"
  pkg_log INFO "CMD: ${cmd}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    pkg_log INFO "DRY-RUN: ${cmd}"
    return 0
  fi
  # run in subshell to isolate
  ( set -o pipefail; cd "${BUILD_DIR}" && bash -lc "${cmd}" ) >>"${PKG_LOG}" 2>&1
  return $?
}

# execute the build according to method (supports custom)
build_run() {
  ui_start_section "Executando build: ${PKG_NAME}"
  pkg_log INFO "Iniciando execução de build (method=${BUILD_METHOD})"

  local rc=0

  if [[ "${BUILD_METHOD}" == "custom" ]]; then
    if ! declare -F custom_build >/dev/null 2>&1; then
      pkg_log ERROR "custom_build() não definida no contexto atual"
      ui_end_fail "Build"
      return 2
    fi
    pkg_log INFO "Executando custom_build() para ${PKG_NAME}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      pkg_log INFO "DRY-RUN: não executando custom_build()"
      ui_end_ok "Build (simulado)"
      return 0
    fi
    # run custom_build in a subshell to capture rc and not pollute env
    ( set -o pipefail; custom_build ) >>"${PKG_LOG}" 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      pkg_log ERROR "custom_build() retornou código $rc"
      if [[ "${STRICT}" -eq 1 ]]; then
        ui_end_fail "Build"
        return "$rc"
      fi
    fi
    ui_end_ok "Build custom"
    return "$rc"
  fi

  # Non-custom methods: run known sequences
  case "${BUILD_METHOD}" in
    autotools)
      # typical: ./configure --prefix=/usr && make -j$JOBS && make DESTDIR=$DESTDIR install
      run_in_build "./configure --prefix=/usr" || rc=$?
      if [[ "$rc" -ne 0 ]]; then pkg_log ERROR "configure falhou (rc=$rc)"; fi
      run_in_build "make -j\$(nproc)" || rc=$(( rc==0 ? $? : rc ))
      if [[ "$rc" -ne 0 ]]; then pkg_log ERROR "make falhou (rc=$rc)"; fi
      ;;
    cmake)
      run_in_build "mkdir -p build && cd build && cmake .. -DCMAKE_INSTALL_PREFIX=/usr" || rc=$?
      run_in_build "cd build && make -j\$(nproc)" || rc=$(( rc==0 ? $? : rc ))
      ;;
    meson)
      run_in_build "meson setup builddir" || rc=$?
      run_in_build "ninja -C builddir -j\$(nproc)" || rc=$(( rc==0 ? $? : rc ))
      ;;
    rust)
      run_in_build "cargo build --release" || rc=$?
      ;;
    python)
      # prefer pyproject build if present
      if [[ -f "${BUILD_DIR}/pyproject.toml" ]]; then
        run_in_build "python3 -m build" || rc=$?
      else
        run_in_build "python3 setup.py build" || rc=$?
      fi
      ;;
    golang)
      run_in_build "go build ./..." || rc=$?
      ;;
    node)
      # npm install then build if script defined
      run_in_build "npm ci || npm install" || rc=$?
      # try to run build script if present
      if grep -q '"build"' "${BUILD_DIR}/package.json" 2>/dev/null; then
        run_in_build "npm run build" || rc=$(( rc==0 ? $? : rc ))
      fi
      ;;
    zig)
      run_in_build "zig build" || rc=$?
      ;;
    gradle)
      run_in_build "./gradlew build" || rc=$?
      ;;
    scons)
      run_in_build "scons -j\$(nproc)" || rc=$?
      ;;
    qmake)
      run_in_build "qmake && make -j\$(nproc)" || rc=$?
      ;;
    make)
      run_in_build "make -j\$(nproc)" || rc=$?
      ;;
    manual)
      pkg_log WARN "Método manual - nenhuma ação automática detectada"
      if [[ "${AUTO_YES}" -eq 0 ]]; then
        if ! confirm "Nenhum método detectado para ${PKG_NAME}. Deseja abrir um shell no build dir para executar manualmente?"; then
          pkg_log WARN "Usuário optou por não executar manualmente"
          ui_end_fail "Build (manual)"
          return 3
        fi
      fi
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        pkg_log INFO "DRY-RUN: não entrando em shell interativo"
        ui_end_ok "Build (simulado manual)"
        return 0
      fi
      # open interactive shell
      pkg_log INFO "Abrindo shell interativo em ${BUILD_DIR} para build manual"
      ( cd "${BUILD_DIR}" && ${SHELL:-/bin/bash} )
      ;;
    *)
      pkg_log ERROR "Método desconhecido: ${BUILD_METHOD}"
      rc=4
      ;;
  esac

  if [[ "$rc" -ne 0 ]]; then
    pkg_log ERROR "Build falhou com rc=$rc (ver ${PKG_LOG})"
    ui_end_fail "Build"
    if [[ "${STRICT}" -eq 1 ]]; then
      return "$rc"
    fi
    return "$rc"
  fi

  ui_end_ok "Build"
  pkg_log INFO "Build executado com sucesso"
  return 0
}

# install step: standardize installation into DESTDIR, register package
build_install() {
  ui_start_section "Instalando ${PKG_NAME}"
  pkg_log INFO "Iniciando instalação"

  local DESTDIR="${ADM_TMP}/install-${PKG_NAME}-${TS}"
  safe_mkdir "${DESTDIR}"

  local rc=0

  case "${BUILD_METHOD}" in
    autotools|make|qmake)
      run_in_build "make DESTDIR='${DESTDIR}' install" || rc=$?
      ;;
    cmake)
      run_in_build "cd build && make DESTDIR='${DESTDIR}' install" || rc=$?
      ;;
    meson)
      run_in_build "ninja -C builddir install DESTDIR='${DESTDIR}'" || rc=$?
      ;;
    rust)
      # Rust crates usually produce binaries; attempt to install to DESTDIR via cargo install if defined
      if [[ -f "${BUILD_DIR}/Cargo.toml" ]]; then
        run_in_build "cargo install --path . --root '${DESTDIR}'" || rc=$?
      fi
      ;;
    python)
      # install into DESTDIR using pip if wheel produced or setup.py
      if [[ -f "${BUILD_DIR}/dist/"*".whl" ]] 2>/dev/null; then
        run_in_build "pip3 install --no-deps --prefix='${DESTDIR}' dist/*.whl" || rc=$?
      else
        run_in_build "python3 setup.py install --root='${DESTDIR}' --prefix='/'" || rc=$?
      fi
      ;;
    node)
      # try npm install to destination via prefix or copy dist
      run_in_build "npm pack" || true
      # fallback: copy build artifacts if any
      ;;
    golang)
      # go install can install to GOBIN; do best-effort: copy binary to DESTDIR/usr/bin
      run_in_build "go install ./..." || rc=$?
      ;;
    custom)
      # assume custom_build handled install; but still look for conventional install step
      run_in_build "make DESTDIR='${DESTDIR}' install" || true
      ;;
    manual)
      pkg_log WARN "No automatic install step for manual method"
      ;;
    *)
      pkg_log WARN "Instalação não implementada para método ${BUILD_METHOD}"
      ;;
  esac

  # if rc nonzero and strict -> fail
  if [[ "$rc" -ne 0 ]]; then
    pkg_log ERROR "Instalação retornou rc=$rc"
    ui_end_fail "Instalação"
    if [[ "${STRICT}" -eq 1 ]]; then return "$rc"; fi
  fi

  # post-install actions: move DESTDIR contents to a package cache or final location
  # default: copy into ${ADM_DB}/packages/<pkg>/<version> as installed snapshot
  local final_dir="${ADM_DB}/packages/${PKG_NAME}/${PKG_VERSION}"
  safe_mkdir "${final_dir}"
  # copy content of DESTDIR root to final_dir (preserve)
  if [[ -d "${DESTDIR}" ]]; then
    # use rsync if available for safety else cp -a
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "${DESTDIR}/" "${final_dir}/" >>"${PKG_LOG}" 2>&1 || true
    else
      cp -a "${DESTDIR}/." "${final_dir}/" >>"${PKG_LOG}" 2>&1 || true
    fi
    pkg_log INFO "Conteúdo instalado copiado para ${final_dir}"
  fi

  # register package in adm.db
  safe_mkdir "${ADM_DB}"
  local dbf="${ADM_DB}/adm.db"
  printf "%s|%s|%s\n" "${PKG_NAME}" "${PKG_VERSION}" "$(date '+%F %T')" >>"${dbf}"
  pkg_log INFO "Registrado no adm.db: ${PKG_NAME}|${PKG_VERSION}"

  # run post-install hooks if present
  if [[ -x "${ADM_SCRIPTS}/hooks.sh" ]]; then
    "${ADM_SCRIPTS}/hooks.sh" --pkg "${PKG_NAME}" --run install post >>"${PKG_LOG}" 2>&1 || true
  fi

  ui_end_ok "Instalação"
  return 0
}

# cleanup: remove build dir, lock, temp files
build_cleanup() {
  ui_start_section "Finalizando build"
  local rc=0
  # post-build hook
  if [[ -x "${ADM_SCRIPTS}/hooks.sh" ]]; then
    "${ADM_SCRIPTS}/hooks.sh" --pkg "${PKG_NAME}" --run build post >>"${PKG_LOG}" 2>&1 || true
  fi

  if [[ "${KEEP_BUILD_DIR}" -eq 0 ]]; then
    pkg_log INFO "Removendo build dir ${BUILD_DIR}"
    rm -rf "${BUILD_DIR}" || pkg_log WARN "Falha ao remover ${BUILD_DIR}"
  else
    pkg_log INFO "Mantendo build dir ${BUILD_DIR} (keep set)"
  fi

  # remove lock file
  rm -f "${ADM_TMP}/build-${PKG_NAME}.lock" 2>/dev/null || true

  END_TS="$(date +%s)"
  local elapsed=$(( END_TS - START_TS ))
  pkg_log INFO "Tempo total: ${elapsed}s"
  ui_end_ok "Finalização"
  return $rc
}

# summary
build_summary() {
  ui_start_section "Resumo do build"
  local elapsed=$(( END_TS - START_TS ))
  printf "Pacote: %s\nVersão: %s\nMétodo: %s\nTempo(s): %d\nLog: %s\n" \
    "${PKG_NAME}" "${PKG_VERSION}" "${BUILD_METHOD}" "${elapsed}" "${PKG_LOG}"
  ui_end_ok "Resumo"
  # also append to global log
  log_info "Build summary: ${PKG_NAME} ${PKG_VERSION} method=${BUILD_METHOD} time=${elapsed}s log=${PKG_LOG}"
}

# -------------------------
# CLI parsing and main flow
# -------------------------
_print_usage() {
  cat <<EOF
build.sh - ADM build script
Usage:
  build.sh --pkg <name> [options]
Options:
  --pkg <name>         Package name (required)
  --method <name>      Force build method (autotools, cmake, meson, rust, python, make, custom, manual, etc.)
  --keep               Keep build dir after completion
  --resume             Resume previous build if found
  --strict             Abort on first error
  --yes                 Assume yes to prompts
  --dry-run            Do not execute build commands
  --debug              Verbose debug mode
  --help
EOF
}

# parse args
if (( $# -gt 0 )); then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pkg) PKG_NAME="${2:-}"; shift 2 ;;
      --method) METHOD_OVERRIDE="${2:-}"; shift 2 ;;
      --keep) KEEP_BUILD_DIR=1; shift ;;
      --resume) RESUME=1; shift ;;
      --strict) STRICT=1; shift ;;
      --yes|-y) AUTO_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --debug) DEBUG=1; VERBOSE=1; shift ;;
      --help|-h) _print_usage; exit 0 ;;
      *) echo "Unknown arg: $1"; _print_usage; exit 2 ;;
    esac
  done
fi

# validate
if [[ -z "${PKG_NAME:-}" ]]; then
  echo "Error: --pkg required"
  _print_usage
  exit 2
fi

# main pipeline
if ! build_load_conf "${PKG_NAME}"; then
  log_error "Falha ao carregar build.conf para ${PKG_NAME}"
  exit 2
fi

# Prepare build dir, deps, fetch, extract
if ! build_prepare; then
  log_error "Falha na preparação do build"
  exit 3
fi

# detect method (and load/handle custom_build)
if ! build_detect_method; then
  log_error "Falha na detecção do método de build"
  exit 4
fi

# run pre-build hooks if available (hooks.sh)
if [[ -x "${ADM_SCRIPTS}/hooks.sh" ]]; then
  "${ADM_SCRIPTS}/hooks.sh" --pkg "${PKG_NAME}" --run build pre >>"${PKG_LOG}" 2>&1 || true
fi

# run build
if ! build_run; then
  log_error "Build falhou para ${PKG_NAME}"
  if [[ "${STRICT}" -eq 1 ]]; then
    build_cleanup
    exit 5
  fi
fi

# install
if ! build_install; then
  log_error "Instalação falhou para ${PKG_NAME}"
  if [[ "${STRICT}" -eq 1 ]]; then
    build_cleanup
    exit 6
  fi
fi

# cleanup and summary
build_cleanup
build_summary

# exit success
exit 0
