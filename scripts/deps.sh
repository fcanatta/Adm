#!/usr/bin/env bash
# /usr/src/adm/scripts/deps.sh
# ADM Build System - Dependency resolver (compilation deps)
# Version: 1.0
# Author: ADM Build (generated)
# Purpose: read build.conf DEPEND=, resolve recursively, detect cycles, produce ordered list
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

# CLI flags
PKG_NAME=""
ACTION="resolve"        # default action
STRICT=0
DRY_RUN=0
DEBUG=0
AUTO_YES=0
BUILD_MISSING=0
VERBOSE=0
OUT_ORDER=""
OUT_TREE=""

LOGFILE="${ADM_LOGS}/deps-${TS}.log"
mkdir -p "${ADM_LOGS}" "${ADM_DB}" "${ADM_TMP}" 2>/dev/null || true
touch "${LOGFILE}" 2>/dev/null || true

# Try to source helpers, non-fatal
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
# Logging helpers (local fallback)
# -------------------------
_now() { date '+%Y-%m-%d %H:%M:%S'; }

log_write() {
  local lvl="$1"; shift
  local msg="$*"
  printf "%s [%s] %s\n" "$(_now)" "$lvl" "$msg" >>"${LOGFILE}"
  # if project log.sh exists and defines log_info/log_warn/log_error, call them
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

# -------------------------
# Utilities
# -------------------------
safe_mkdir() { mkdir -p "$1"; chmod 0755 "$1" 2>/dev/null || true; }
confirm() {
  if [[ "${AUTO_YES}" -eq 1 ]]; then return 0; fi
  printf "%s [y/N]: " "$1"
  read -r ans
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

# normalize package dir (search repo)
pkg_dir_from_name() {
  local name="$1"
  if [[ -d "${ADM_REPO}/${name}" ]]; then
    printf "%s\n" "$(readlink -f "${ADM_REPO}/${name}")"
    return 0
  fi
  # try to find within repo (depth 3)
  local found
  found="$(find "${ADM_REPO}" -maxdepth 3 -type d -name "${name}" -print -quit 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    printf "%s\n" "$(readlink -f "$found")"
    return 0
  fi
  return 2
}

# read build.conf key safely (KEY=VALUE)
read_build_key() {
  local conf="$1" key="$2"
  if [[ ! -r "$conf" ]]; then
    return 1
  fi
  # grep key=, allow quotes
  awk -F= -v k="$key" '
    $0 ~ "^"k"=" {
      $1=""; sub(/^=/,"",$0);
      val=$0; gsub(/^[[:space:]]*/,"",val); gsub(/[[:space:]]*$/,"",val);
      gsub(/^"|"$/,"",val); gsub(/^'\''|'\''$/,"",val);
      print val; exit
    }' "$conf" || true
}

# parse DEPEND line into array (space or comma separated)
parse_depend_field() {
  local raw="$1"
  local -n __out=$2
  __out=()
  [[ -z "${raw:-}" ]] && return 0
  # unify commas -> spaces
  raw="${raw//,/ }"
  # split
  local token
  for token in $raw; do
    token="${token##*/}"   # strip possible path prefixes
    token="${token%%:*}"   # strip version suffix if present like pkg:ver (we only use name)
    token="${token//[[:space:]]/}"
    if [[ -n "$token" ]]; then __out+=("$token"); fi
  done
}

# write ordered list and tree output
write_outputs() {
  local pkg="$1"
  local -n order_ref=$2
  local -n tree_ref=$3
  safe_mkdir "${ADM_DB}"
  local order_file="${ADM_DB}/deps-resolved-${pkg}.lst"
  local tree_file="${ADM_DB}/deps-tree-${pkg}.tree"
  if [[ -n "${OUT_ORDER}" ]]; then order_file="${OUT_ORDER}"; fi
  if [[ -n "${OUT_TREE}" ]]; then tree_file="${OUT_TREE}"; fi

  printf "%s\n" "${order_ref[@]}" >"${order_file}.tmp" || true
  mv -f "${order_file}.tmp" "${order_file}"
  printf "%s\n" "${tree_ref[@]}" >"${tree_file}.tmp" || true
  mv -f "${tree_file}.tmp" "${tree_file}"
  log_info "Outputs escritos: ${order_file}, ${tree_file}"
  echo "${order_file}" "${tree_file}"
}

# -------------------------
# Core dependency resolver (data structures)
# -------------------------
declare -A DEPS_MAP       # package -> space-separated dependencies
declare -A VISITED        # package -> 0/1 (checked)
declare -A TEMP_MARK      # package -> 0/1 (for cycle detection)
declare -A EXISTING_INSTALLED  # package -> 0/1 found in adm.db (installed)
ORDER_LIST=()             # topological order (reversed at end)
TREE_LINES=()             # textual tree lines

# read build.conf and load DEPEND into DEPS_MAP[pkg]
load_pkg_deps() {
  local pkg="$1"
  local pkgdir
  if ! pkgdir="$(pkg_dir_from_name "$pkg" 2>/dev/null)"; then
    log_warn "Pacote não encontrado em repo: $pkg"
    DEPS_MAP["$pkg"]=""
    return 1
  fi
  local conf="${pkgdir}/build.conf"
  local raw
  raw="$(read_build_key "$conf" "DEPEND" || true)"
  if [[ -z "${raw:-}" ]]; then
    DEPS_MAP["$pkg"]=""
    log_info "Nenhuma dependência declarada para $pkg"
    return 0
  fi
  local deps_arr=()
  parse_depend_field "$raw" deps_arr
  DEPS_MAP["$pkg"]="${deps_arr[*]}"
  log_info "Lidas dependências de $pkg: ${DEPS_MAP[$pkg]}"
  return 0
}

# check if package installed (simple adm.db scan)
check_installed_db() {
  local pkg="$1"
  # if adm.db doesn't exist or no record, return 1
  local dbf="${ADM_DB}/adm.db"
  if [[ ! -f "$dbf" ]]; then
    EXISTING_INSTALLED["$pkg"]=0
    return 1
  fi
  # adm.db expected to have lines like: pkg|version|installed_at|...
  if grep -E "^${pkg}\\|" "$dbf" >/dev/null 2>&1; then
    EXISTING_INSTALLED["$pkg"]=1
    return 0
  fi
  EXISTING_INSTALLED["$pkg"]=0
  return 1
}

# -------------------------
# DFS resolver with cycle detection
# -------------------------
dfs_resolve() {
  local pkg="$1"
  local indent="$2"   # for tree printing
  # if visited, skip
  if [[ "${VISITED[$pkg]:-0}" -eq 1 ]]; then
    TREE_LINES+=("${indent}${pkg} (already resolved)")
    return 0
  fi
  # cycle detection
  if [[ "${TEMP_MARK[$pkg]:-0}" -eq 1 ]]; then
    log_error "Ciclo detectado envolvendo: $pkg"
    TREE_LINES+=("${indent}${pkg} (CYCLE DETECTED)")
    if [[ "${STRICT}" -eq 1 ]]; then
      log_error "Modo strict: abortando por ciclo"
      exit 1
    fi
    return 2
  fi
  TEMP_MARK["$pkg"]=1
  # ensure deps known for pkg
  if [[ -z "${DEPS_MAP[$pkg]+_}" ]]; then
    load_pkg_deps "$pkg" || true
  fi
  # report installed state
  check_installed_db "$pkg" || true
  local inst="${EXISTING_INSTALLED[$pkg]:-0}"
  if [[ "${inst}" -eq 1 ]]; then
    TREE_LINES+=("${indent}${pkg} [installed]")
  else
    TREE_LINES+=("${indent}${pkg}")
  fi

  # iterate dependencies
  local deps="${DEPS_MAP[$pkg]:-}"
  if [[ -n "$deps" ]]; then
    local dep
    for dep in $deps; do
      dfs_resolve "$dep" "  ${indent}"
      # if cycle and strict, abort
      if [[ "${TEMP_MARK[$dep]:-0}" -eq 1 && "${STRICT}" -eq 1 ]]; then
        log_error "Abortando por ciclo detectado em ${dep}"
        exit 1
      fi
    done
  fi

  TEMP_MARK["$pkg"]=0
  VISITED["$pkg"]=1
  # prepend to order (we will reverse at end)
  ORDER_LIST+=("$pkg")
  return 0
}
# reverse ORDER_LIST to get correct topological build order (dependencies first)
finalize_order() {
  # ORDER_LIST currently has nodes pushed after DFS completion (post-order)
  # reversing gives build order: dependencies before dependents
  local -a rev=()
  local i
  for (( i=${#ORDER_LIST[@]}-1; i>=0; i-- )); do
    rev+=( "${ORDER_LIST[i]}" )
  done
  ORDER_LIST=("${rev[@]}")
  log_info "Ordem topológica finalizada: ${ORDER_LIST[*]}"
}

# find missing dependencies (not installed)
collect_missing() {
  MISSING_LIST=()
  for p in "${ORDER_LIST[@]}"; do
    # if installed, skip
    if [[ "${EXISTING_INSTALLED[$p]:-0}" -eq 1 ]]; then
      continue
    fi
    MISSING_LIST+=( "$p" )
  done
  if (( ${#MISSING_LIST[@]} == 0 )); then
    log_info "Nenhuma dependência ausente"
  else
    log_warn "Dependências ausentes detectadas: ${MISSING_LIST[*]}"
  fi
}

# write outputs (order and tree) and show report
report_and_write() {
  finalize_order
  # prepare tree lines maybe already in TREE_LINES
  # If tree lines empty, create a simple representation
  if (( ${#TREE_LINES[@]} == 0 )); then
    TREE_LINES=("Dependency tree for ${PKG_NAME}:")
    for p in "${ORDER_LIST[@]}"; do TREE_LINES+=(" - ${p}"); done
  fi

  # write outputs
  local out_order_file out_tree_file
  read -r out_order_file out_tree_file <<< "$(write_outputs "${PKG_NAME}" ORDER_LIST TREE_LINES)"
  # summary on stdout / UI
  ui_start_section "Resumo de dependências para ${PKG_NAME}"
  printf "Pacote: %s\n" "${PKG_NAME}"
  printf "Total (incluindo o pacote): %d\n" "${#ORDER_LIST[@]}"
  printf "Ausentes: %d\n" "${#MISSING_LIST[@]:-0}"
  printf "Ordem escrita em: %s\n" "${out_order_file}"
  printf "Árvore escrita em: %s\n" "${out_tree_file}"
  ui_end_ok "Resumo de dependências"
  log_info "Resumo gerado para ${PKG_NAME}"
}

# attempt to build missing dependencies
build_missing_deps() {
  if (( ${#MISSING_LIST[@]} == 0 )); then
    log_info "Nenhuma dependência para construir."
    return 0
  fi

  ui_start_section "Construindo dependências ausentes (${#MISSING_LIST[@]})"
  # prefer scheduler if available
  if [[ -x "${ADM_SCRIPTS}/scheduler.sh" ]]; then
    log_info "Usando scheduler para construir dependências..."
    for p in "${MISSING_LIST[@]}"; do
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "DRY-RUN scheduler: agendaria ${p}"
        continue
      fi
      # call scheduler to enqueue and process single package (scheduler interface may vary)
      # we'll try a safe invocation: scheduler.sh --pkg <p> --run (some schedulers have different CLIs)
      if "${ADM_SCRIPTS}/scheduler.sh" --pkg "${p}" --single >/dev/null 2>>"${LOGFILE}"; then
        log_info "Scheduler solicitou build para ${p}"
      else
        log_warn "Scheduler falhou para ${p}. Tentando build.sh diretamente..."
        # fallback to build.sh
        if [[ -x "${ADM_SCRIPTS}/build.sh" ]]; then
          if "${ADM_SCRIPTS}/build.sh" --pkg "${p}" --yes >>"${LOGFILE}" 2>&1; then
            log_info "Build direto bem-sucedido para ${p}"
          else
            log_error "Build direto falhou para ${p} (ver ${LOGFILE})"
            if [[ "${STRICT}" -eq 1 ]]; then
              ui_end_fail "Construção de dependências (abortado)"
              return 2
            fi
          fi
        else
          log_error "Nenhuma forma de construir ${p} (scheduler.sh e build.sh ausentes)"
          if [[ "${STRICT}" -eq 1 ]]; then
            ui_end_fail "Construção de dependências (abortado)"
            return 2
          fi
        fi
      fi
    done
  else
    # no scheduler: try build.sh for each missing
    log_info "scheduler.sh não encontrado; usando build.sh diretamente para dependências"
    if [[ ! -x "${ADM_SCRIPTS}/build.sh" ]]; then
      log_error "build.sh ausente — não é possível construir dependências automaticamente"
      ui_end_fail "Construção de dependências"
      return 2
    fi
    for p in "${MISSING_LIST[@]}"; do
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "DRY-RUN build: construir ${p}"
        continue
      fi
      if "${ADM_SCRIPTS}/build.sh" --pkg "${p}" --yes >>"${LOGFILE}" 2>&1; then
        log_info "Build ok: ${p}"
      else
        log_error "Build falhou: ${p}"
        if [[ "${STRICT}" -eq 1 ]]; then
          ui_end_fail "Construção de dependências (abortado)"
          return 2
        fi
      fi
    done
  fi

  ui_end_ok "Construção de dependências completa"
  return 0
}

# check consistency after possible builds: re-check installed
recheck_installed_after_builds() {
  for p in "${ORDER_LIST[@]}"; do
    check_installed_db "$p" || true
  done
}

# CLI parsing (if not parsed before)
_print_usage() {
  cat <<EOF
deps.sh - resolve and report compilation dependencies (ADM)
Usage:
  deps.sh --pkg <package> [options]
Options:
  --pkg <name>          Package name (required)
  --resolve             Resolve recursively (default)
  --order-out <file>    Write ordered list to file
  --tree-out <file>     Write tree output to file
  --build-missing       Attempt to build missing dependencies
  --strict              Abort on first critical error (cycles/build fail)
  --dry-run             Do not perform builds; only simulate
  --debug               Verbose debug mode
  --yes                 Assume yes for prompts
  --help
EOF
}

# parse args if not parsed earlier
if (( $# -gt 0 )); then
  # quick parser for options (allow calling script standalone)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pkg) PKG_NAME="${2:-}"; shift 2 ;;
      --resolve) ACTION="resolve"; shift ;;
      --order-out) OUT_ORDER="${2:-}"; shift 2 ;;
      --tree-out) OUT_TREE="${2:-}"; shift 2 ;;
      --build-missing) BUILD_MISSING=1; shift ;;
      --strict) STRICT=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --debug) DEBUG=1; VERBOSE=1; shift ;;
      --yes|-y) AUTO_YES=1; shift ;;
      --help|-h) _print_usage; exit 0 ;;
      *) echo "Unknown arg: $1"; _print_usage; exit 2 ;;
    esac
  done
fi

# validate
if [[ -z "${PKG_NAME:-}" ]]; then
  log_error "Parâmetro --pkg obrigatório"
  _print_usage
  exit 2
fi

# main flow
ui_start_section "Verificação de dependências: ${PKG_NAME}"
log_info "Iniciando deps.sh para ${PKG_NAME} (TS=${TS})"

# clear or init structures
ORDER_LIST=()
TREE_LINES=()
MISSING_LIST=()

# resolve recursively with DFS
# start resolution
if ! dfs_resolve "${PKG_NAME}" ""; then
  log_warn "dfs_resolve retornou não-zero; prosseguindo conforme modo"
fi

# produce final order and tree
collect_missing
report_and_write

# optionally build missing dependencies
if [[ "${BUILD_MISSING}" -eq 1 ]]; then
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "DRY-RUN: não será construído (build-missing)"
  else
    if ! build_missing_deps; then
      log_error "Falha ao construir dependências ausentes"
      if [[ "${STRICT}" -eq 1 ]]; then
        ui_end_fail "deps.sh (abortado)"
        exit 1
      fi
    else
      # re-evaluate installed state
      recheck_installed_after_builds
      collect_missing
      report_and_write
    fi
  fi
fi

ui_end_ok "deps.sh finalizado para ${PKG_NAME}"
log_info "deps.sh concluído com sucesso para ${PKG_NAME}"
exit 0
