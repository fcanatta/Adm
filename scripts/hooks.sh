#!/usr/bin/env bash
# /usr/src/adm/scripts/hooks.sh
# ADM Build System - package hooks manager
# Version: 1.0
# Purpose: detect, verify and run package-local hooks (pre/post for phases)
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
TS="$(date '+%Y%m%d_%H%M%S')"

# CLI defaults
ACTION="run"         # run | list | verify | summary
RUN_PHASE=""         # like "build", "fetch", "install"
RUN_TYPE=""          # pre | post
PKG_INPUT=""         # package dir or name under repo
STRICT=0             # if 1, abort on hook failure
DEBUG=0
AUTO_YES=0
VERBOSE=0
DRY_RUN=0

# runtime vars filled after init
PKG_DIR=""
PKG_NAME=""
PKG_VERSION="unknown"
HOOK_DIRS=()
HOOK_LIST=()         # array of found hooks (full paths)
LOGFILE=""
HISTORY_DB="${ADM_DB}/hooks-history.db"

mkdir -p "${ADM_LOGS}" "${ADM_DB}" 2>/dev/null || true

# Try source helpers (non-fatal)
if [[ -r "${ADM_SCRIPTS}/env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_SCRIPTS}/env.sh" || true
fi
_LOG_PRESENT=no
_UI_PRESENT=no
if [[ -r "${ADM_SCRIPTS}/log.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_SCRIPTS}/log.sh" || true
  _LOG_PRESENT=yes
fi
if [[ -r "${ADM_SCRIPTS}/ui.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_SCRIPTS}/ui.sh" || true
  _UI_PRESENT=yes
fi

# -------------------------
# Logging / UI wrappers
# -------------------------
_now() { date '+%Y-%m-%d %H:%M:%S'; }
log_write() {
  local lvl="$1"; shift
  local msg="$*"
  printf "%s [%s] %s\n" "$(_now)" "$lvl" "$msg" >>"${LOGFILE}"
  if [[ "${_LOG_PRESENT}" == "yes" && "$(type -t log_${lvl} 2>/dev/null)" == "function" ]]; then
    # call project's log wrapper if exists
    log_"${lvl}" "$msg"
  else
    if [[ "${VERBOSE}" -eq 1 ]]; then
      printf "[%s] %s\n" "$lvl" "$msg"
    fi
  fi
}
log_info()  { log_write info  "$*"; }
log_warn()  { log_write warn  "$*"; }
log_error() { log_write error "$*"; }

ui_section_start() {
  local title="$1"
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_section 2>/dev/null)" == "function" ]]; then
    ui_section "$title"
  else
    printf "[  ] %s\n" "$title"
  fi
}
ui_section_end_ok() {
  local title="$1"
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_end_section 2>/dev/null)" == "function" ]]; then
    ui_end_section 0 "$title"
  else
    printf "[✔️] %s... concluído\n" "$title"
  fi
}
ui_section_end_fail() {
  local title="$1"
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_end_section 2>/dev/null)" == "function" ]]; then
    ui_end_section 1 "$title"
  else
    printf "[✖] %s... falhou\n" "$title"
  fi
}
ui_info() {
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_info 2>/dev/null)" == "function" ]]; then
    ui_info "$*"
  else
    printf "[i] %s\n" "$*"
  fi
}

# -------------------------
# Helpers
# -------------------------
safe_mkdir() { mkdir -p "$1"; chmod 0755 "$1" 2>/dev/null || true; }

confirm() {
  if [[ "${AUTO_YES}" -eq 1 ]]; then return 0; fi
  printf "%s [y/N]: " "$1"
  read -r ans
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

# normalize package input into PKG_DIR, PKG_NAME
normalize_pkg_dir() {
  local input="$1"
  if [[ -z "$input" ]]; then return 1; fi
  # explicit path?
  if [[ -d "$input" ]]; then
    PKG_DIR="$(readlink -f "$input")"
    PKG_NAME="$(basename "$PKG_DIR")"
    return 0
  fi
  # try under ADM_REPO directly
  if [[ -d "${ADM_REPO}/$input" ]]; then
    PKG_DIR="$(readlink -f "${ADM_REPO}/$input")"
    PKG_NAME="$input"
    return 0
  fi
  # try to find package name anywhere in repo (maxdepth 3)
  local found
  found="$(find "${ADM_REPO}" -maxdepth 3 -type d -name "$input" -print -quit 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    PKG_DIR="$(readlink -f "$found")"
    PKG_NAME="$(basename "$found")"
    return 0
  fi
  return 2
}

# detect version from build.conf if present
detect_pkg_version() {
  PKG_VERSION="unknown"
  if [[ -f "${PKG_DIR}/build.conf" ]]; then
    PKG_VERSION="$(awk -F= '/^VERSION=/{gsub(/"/,"",$2); print $2; exit}' "${PKG_DIR}/build.conf" || true)"
    PKG_VERSION="${PKG_VERSION:-unknown}"
  fi
}

# assemble hook dirs (patch/patches like detection but for hooks)
detect_hook_dirs() {
  HOOK_DIRS=()
  if [[ -d "${PKG_DIR}/hooks" ]]; then HOOK_DIRS+=("${PKG_DIR}/hooks"); fi
  if [[ -d "${PKG_DIR}/hook" ]]; then HOOK_DIRS+=("${PKG_DIR}/hook"); fi
}

# find all hooks (optionally filter by phase/type)
# params: [phase] [type]
detect_hooks() {
  local phase="${1:-}" type="${2:-}"
  HOOK_LIST=()
  detect_hook_dirs
  for hd in "${HOOK_DIRS[@]}"; do
    # match patterns: pre-<phase>.*, post-<phase>.*, or generic <phase>-pre.*? we keep standard pre/post
    if [[ -n "$phase" && -n "$type" ]]; then
      while IFS= read -r -d '' f; do HOOK_LIST+=("$f"); done < <(find "$hd" -maxdepth 1 -type f -name "${type}-${phase}.*" -o -name "${type}-${phase}" -print0 2>/dev/null || true)
    elif [[ -n "$phase" ]]; then
      while IFS= read -r -d '' f; do HOOK_LIST+=("$f"); done < <(find "$hd" -maxdepth 1 -type f \( -name "pre-${phase}.*" -o -name "post-${phase}.*" -o -name "pre-${phase}" -o -name "post-${phase}" \) -print0 2>/dev/null || true)
    else
      while IFS= read -r -d '' f; do HOOK_LIST+=("$f"); done < <(find "$hd" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null || true)
    fi
  done
  # sort for deterministic order
  if (( ${#HOOK_LIST[@]} > 0 )); then
    IFS=$'\n' HOOK_LIST=($(for p in "${HOOK_LIST[@]}"; do printf '%s\n' "$p"; done | sort)) ; unset IFS
  fi
}

# verify a hook file (permissions + bash syntax)
verify_hook_file() {
  local hf="$1"
  # check executable
  if [[ ! -x "$hf" ]]; then
    log_warn "Hook sem +x: $hf"
    return 2
  fi
  # basic syntax check with bash -n
  if ! bash -n "$hf" 2>/dev/null; then
    log_warn "Hook com erro de sintaxe: $hf"
    return 3
  fi
  return 0
}

# record history: ACTION|PKG|VER|HOOK|STATUS|MSG|TS
record_history() {
  local action="$1"; local hook="$2"; local status="$3"; local msg="$4"
  safe_mkdir "$(dirname "$HISTORY_DB")"
  printf "%s|%s|%s|%s|%s|%s\n" "$(_now)" "${PKG_NAME}" "${PKG_VERSION}" "${action}" "${hook}" "${status}" >>"${HISTORY_DB}"
}

# run a hook safely
run_hook_file() {
  local hf="$1"
  local hookname
  hookname="$(basename "$hf")"
  local start end rc out err
  log_info "Running hook: ${hookname} (path=${hf})"
  # verify before run
  if ! verify_hook_file "$hf"; then
    log_warn "Hook $hookname inválido/sem permissão - ignorando"
    record_history "SKIP" "$hookname" "INVALID" ""
    return 0
  fi

  # prepare env for hook
  local envfile
  envfile="$(mktemp)"
  {
    printf "PKG_NAME=%q\n" "${PKG_NAME}"
    printf "PKG_VERSION=%q\n" "${PKG_VERSION}"
    printf "ADM_BASE=%q\n" "${ADM_BASE}"
    printf "ADM_REPO=%q\n" "${ADM_REPO}"
    printf "ADM_LOGS=%q\n" "${ADM_LOGS}"
    printf "ADM_DB=%q\n" "${ADM_DB}"
    printf "HOOK_DIR=%q\n" "${HOOK_DIRS[0]:-}"
  } >"$envfile"

  # run hook in subshell to avoid polluting environment
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "DRY-RUN: would execute $hf"
    record_history "DRYRUN" "$hookname" "DRY" ""
    rm -f "$envfile"
    return 0
  fi

  # capture stdout/stderr to temp files
  local stdoutf stderrf
  stdoutf="$(mktemp)"
  stderrf="$(mktemp)"
  start="$(_now)"
  # export env and run
  if ( set -o pipefail; . "$envfile"; bash "$hf" ) >"$stdoutf" 2>"$stderrf"; then
    rc=0
  else
    rc=$?
  fi
  end="$(_now)"

  # write outputs to main log (annotated)
  {
    printf "\n--- HOOK START: %s (%s) ---\n" "$hookname" "$start"
    printf "[STDOUT]\n"; cat "$stdoutf" || true
    printf "\n[STDERR]\n"; cat "$stderrf" || true
    printf "\n--- HOOK END: %s (%s) rc=%d ---\n" "$hookname" "$end" "$rc"
  } >>"${LOGFILE}"

  # cleanup
  rm -f "$envfile" "$stdoutf" "$stderrf" 2>/dev/null || true

  if [[ "$rc" -eq 0 ]]; then
    log_info "Hook succeeded: $hookname"
    record_history "RUN" "$hookname" "OK" ""
    return 0
  else
    log_warn "Hook failed (rc=$rc): $hookname"
    record_history "RUN" "$hookname" "FAIL" ""
    return "$rc"
  fi
}

# -------------------------
# Phase implementations
# -------------------------
hooks_init() {
  ui_section_start "Inicializando hooks manager"
  # PKG_INPUT must be normalized
  if [[ -z "${PKG_INPUT}" ]]; then
    log_error "Parametro --pkg obrigatório"
    ui_section_end_fail "Inicialização"
    exit 2
  fi
  if ! normalize_pkg_dir "${PKG_INPUT}"; then
    log_error "Pacote não encontrado: ${PKG_INPUT}"
    ui_section_end_fail "Inicialização"
    exit 2
  fi
  detect_pkg_version
  LOGFILE="${ADM_LOGS}/hooks-${PKG_NAME}-${PKG_VERSION}-${TS}.log"
  touch "${LOGFILE}" 2>/dev/null || true
  detect_hook_dirs
  log_info "Hooks init: pkg=${PKG_NAME}, dir=${PKG_DIR}, hooks_dirs=${HOOK_DIRS[*]:-none}, log=${LOGFILE}"
  ui_section_end_ok "Inicialização"
}

hooks_list() {
  detect_hooks
  if (( ${#HOOK_LIST[@]} == 0 )); then
    ui_info "Nenhum hook encontrado em ${PKG_DIR}/hooks{,s}"
    return 0
  fi
  ui_section_start "Lista de hooks detectados"
  for h in "${HOOK_LIST[@]}"; do
    local ok=.
    if [[ -x "$h" ]]; then ok="OK"; else ok="NOX"; fi
    printf "%-8s %s\n" "$ok" "$(basename "$h")"
  done
  ui_section_end_ok "Listagem completa"
}

hooks_verify_all() {
  detect_hooks
  if (( ${#HOOK_LIST[@]} == 0 )); then
    ui_info "Nenhum hook para verificar"
    return 0
  fi
  ui_section_start "Verificando hooks (permissões e sintaxe)"
  local failed=0
  for h in "${HOOK_LIST[@]}"; do
    if ! verify_hook_file "$h"; then
      log_warn "Hook inválido: $(basename "$h")"
      failed=1
    else
      log_info "Hook OK: $(basename "$h")"
    fi
  done
  ui_section_end_ok "Verificação concluída"
  return $failed
}

hooks_run_phase() {
  local phase="$1" type="$2"
  detect_hooks "$phase" "$type"
  if (( ${#HOOK_LIST[@]} == 0 )); then
    ui_info "Nenhum hook ${type}-${phase} encontrado"
    return 0
  fi

  ui_section_start "Executando hooks ${type}-${phase} (${#HOOK_LIST[@]})"
  local failures=0
  for hf in "${HOOK_LIST[@]}"; do
    ui_section_start "Hook $(basename "$hf")"
    if run_hook_file "$hf"; then
      ui_section_end_ok "Hook $(basename "$hf")"
    else
      ui_section_end_fail "Hook $(basename "$hf")"
      failures=$((failures+1))
      if [[ "${STRICT}" -eq 1 ]]; then
        log_error "Strict mode: abortando após falha em $(basename "$hf")"
        return 2
      fi
    fi
  done
  ui_section_end_ok "Execução hooks ${type}-${phase}"
  if [[ "$failures" -gt 0 ]]; then
    return 1
  fi
  return 0
}

hooks_summary() {
  ui_section_start "Resumo de execução de hooks"
  # count history entries for this package in last run (approx)
  local total=$(grep -c "|${PKG_NAME}|" "${HISTORY_DB}" 2>/dev/null || true)
  ui_info "Histórico (total linhas): ${total} (ver ${HISTORY_DB})"
  ui_section_end_ok "Resumo"
}

# -------------------------
# CLI parsing
# -------------------------
_usage() {
  cat <<EOF
hooks.sh - package-local hooks manager (pre/post)
Usage:
  hooks.sh --pkg <pkg_dir_or_name> [--run <phase> <pre|post>] [--list] [--verify] [--summary] [options]

Actions:
  --run <phase> <type>    Execute hooks for a phase (type pre|post). Example: --run build pre
  --list                  List hooks found for package
  --verify                Verify hooks (permissions + bash syntax)
  --summary               Show summary / history info

Options:
  --pkg <pkg_dir_or_name> Package directory or name under repo (required)
  --strict                Abort on first hook failure
  --debug                 Debug/verbose mode
  --yes                   Non-interactive (auto-confirm)
  --dry-run               Simulate execution (no run)
  --help
EOF
}

if (( $# == 0 )); then
  _usage
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      shift
      RUN_PHASE="${1:-}"; shift
      RUN_TYPE="${1:-}"; shift
      ACTION="run"
      ;;
    --list)
      ACTION="list"; shift
      ;;
    --verify)
      ACTION="verify"; shift
      ;;
    --summary)
      ACTION="summary"; shift
      ;;
    --pkg)
      PKG_INPUT="${2:-}"; shift 2
      ;;
    --strict)
      STRICT=1; shift
      ;;
    --debug)
      DEBUG=1; VERBOSE=1; shift
      ;;
    --yes|-y)
      AUTO_YES=1; shift
      ;;
    --dry-run)
      DRY_RUN=1; shift
      ;;
    --verbose)
      VERBOSE=1; shift
      ;;
    --help|-h)
      _usage; exit 0
      ;;
    *)
      echo "Unknown arg: $1"; _usage; exit 2
      ;;
  esac
done

# -------------------------
# Main
# -------------------------
hooks_init

case "${ACTION}" in
  list)
    detect_hooks
    hooks_list
    exit 0
    ;;
  verify)
    detect_hooks
    if hooks_verify_all; then
      ui_info "All hooks OK"
      exit 0
    else
      ui_info "Some hooks invalid - check logs"
      exit 1
    fi
    ;;
  run)
    if [[ -z "${RUN_PHASE}" || -z "${RUN_TYPE}" ]]; then
      log_error "Uso: --run <phase> <pre|post>"
      _usage
      exit 2
    fi
    if [[ "${RUN_TYPE}" != "pre" && "${RUN_TYPE}" != "post" ]]; then
      log_error "Tipo inválido: ${RUN_TYPE} (use pre|post)"
      exit 2
    fi
    if hooks_run_phase "${RUN_PHASE}" "${RUN_TYPE}"; then
      ui_info "Hooks ${RUN_TYPE}-${RUN_PHASE} finalizados"
      exit 0
    else
      ui_info "Hooks ${RUN_TYPE}-${RUN_PHASE} com falhas (ver ${LOGFILE})"
      exit 1
    fi
    ;;
  summary)
    hooks_summary
    exit 0
    ;;
  *)
    log_error "Ação desconhecida: ${ACTION}"
    exit 2
    ;;
esac
