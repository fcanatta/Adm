#!/usr/bin/env bash
# /usr/src/adm/scripts/patch.sh
# ADM Build System - automatic patch applier
# Version: 1.0
# Behavior: automatically apply all *.patch files from package patch dir
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
PATCH_HISTORY="${ADM_DB}/patch-history.db"
mkdir -p "${ADM_LOGS}" "${ADM_DB}" 2>/dev/null || true

# CLI defaults
ACTION="apply"          # apply | revert | verify | list
PKG_DIR=""              # package directory under ADM_REPO or explicit path
STRICT=0                # abort on first failure
DEBUG=0
AUTO_YES=0
VERBOSE=0
DRY_RUN=0

LOGFILE="${ADM_LOGS}/patch-$(date '+%Y%m%d_%H%M%S').log"
touch "$LOGFILE" 2>/dev/null || true

# Try to source helpers (non-fatal)
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
_log() {
  local lvl="$1"; shift
  local msg="$*"
  printf "%s [%s] %s\n" "$(_now)" "$lvl" "$msg" >>"$LOGFILE"
  if [[ "${_LOG_PRESENT}" == "yes" && "$(type -t log_${lvl} 2>/dev/null)" == "function" ]]; then
    log_"${lvl}" "$msg"
  else
    if [[ "${VERBOSE}" -eq 1 ]]; then
      printf "[%s] %s\n" "$lvl" "$msg"
    fi
  fi
}
log_info(){ _log info "$*"; }
log_warn(){ _log warn "$*"; }
log_error(){ _log error "$*"; }

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

# ensure we are operating inside ADM_REPO path or explicit directory
normalize_pkg_dir() {
  local input="$1"
  if [[ -z "$input" ]]; then return 1; fi
  if [[ -d "$input" ]]; then
    PKG_DIR="$(readlink -f "$input")"
    return 0
  fi
  # try relative under ADM_REPO
  if [[ -d "${ADM_REPO}/$input" ]]; then
    PKG_DIR="$(readlink -f "${ADM_REPO}/$input")"
    return 0
  fi
  # try with category like repo/*/pkg
  local found
  found="$(find "${ADM_REPO}" -maxdepth 3 -type d -name "$input" -print -quit 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    PKG_DIR="$(readlink -f "$found")"
    return 0
  fi
  return 2
}

# list patches in package patch directory
detect_patches() {
  # support patch or patches dir inside package
  PATCH_DIRS=()
  if [[ -d "${PKG_DIR}/patch" ]]; then PATCH_DIRS+=("${PKG_DIR}/patch"); fi
  if [[ -d "${PKG_DIR}/patches" ]]; then PATCH_DIRS+=("${PKG_DIR}/patches"); fi
  PATCH_LIST=()
  for pd in "${PATCH_DIRS[@]}"; do
    while IFS= read -r -d '' f; do
      PATCH_LIST+=("$f")
    done < <(find "$pd" -maxdepth 1 -type f -name '*.patch' -print0 2>/dev/null || true)
  done
  # sort
  if (( ${#PATCH_LIST[@]} > 0 )); then
    IFS=$'\n' PATCH_LIST=($(for p in "${PATCH_LIST[@]}"; do printf "%s\n" "$p"; done | sort)) ; unset IFS
  fi
}

# record history
record_patch_history() {
  # args: action pkg_name pkg_version patchfile status msg
  local line="$(_now)|$1|$2|$3|$4|$5"
  safe_mkdir "$(dirname "$PATCH_HISTORY")"
  printf "%s\n" "$line" >>"$PATCH_HISTORY"
}

# apply single patch, return 0 ok, non-zero fail
apply_patch_file() {
  local patchfile="$1"
  local basedir="$2"   # directory where patch should be applied
  local logfile="$3"   # per-pkg patch log
  # apply with -Np1 (user earlier asked). Use -p1 robustly.
  # We'll try three variants for robustness: -p1, -p0, -Np1 (order)
  local try_opts=("-Np1" "-p1" "-p0")
  local success=1
  for opt in "${try_opts[@]}"; do
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log_info "DRY-RUN: patch ${opt} -i ${patchfile} (cwd=${basedir})"
      success=0
      break
    fi
    # run patch inside basedir
    ( cd "${basedir}" && patch ${opt} -i "${patchfile}" >>"${logfile}" 2>&1 ) && { success=0; break; } || true
  done
  return $success
}

# revert single patch: try -R with same heuristics
revert_patch_file() {
  local patchfile="$1"
  local basedir="$2"
  local logfile="$3"
  local try_opts=("-Np1" "-p1" "-p0")
  local success=1
  for opt in "${try_opts[@]}"; do
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log_info "DRY-RUN: patch -R ${opt} -i ${patchfile} (cwd=${basedir})"
      success=0
      break
    fi
    ( cd "${basedir}" && patch -R ${opt} -i "${patchfile}" >>"${logfile}" 2>&1 ) && { success=0; break; } || true
  done
  return $success
}

# check for .rej or .orig files after apply
check_for_rejects() {
  local basedir="$1"
  local rej_count
  rej_count=$(find "$basedir" -type f \( -name '*.rej' -o -name '*.orig' \) | wc -l || echo 0)
  echo "$rej_count"
}

# pretty basename
pb() { basename "$1"; }

# -------------------------
# Phases
# -------------------------
patch_init() {
  ui_section_start "Inicializando patcher"
  if [[ -z "${PKG_DIR}" ]]; then
    log_error "Nenhum pacote especificado. Use --pkg <pkg_dir>."
    ui_section_end_fail "Inicialização"
    exit 2
  fi
  if ! normalize_pkg_dir "${PKG_DIR}"; then
    log_error "Pacote não encontrado: ${PKG_DIR}"
    ui_section_end_fail "Inicialização"
    exit 2
  fi
  PKG_DIR="$(readlink -f "${PKG_DIR}")"
  PKG_NAME="$(basename "${PKG_DIR}")"
  # try to infer version from parent dir or build.conf if exists
  PKG_VERSION="unknown"
  if [[ -f "${PKG_DIR}/build.conf" ]]; then
    # parse VERSION=
    PKG_VERSION="$(awk -F= '/^VERSION=/{gsub(/"/,"",$2); print $2; exit}' "${PKG_DIR}/build.conf" || true)"
    PKG_VERSION="${PKG_VERSION:-unknown}"
  else
    # parent dir name maybe category; try to find VERSION in sibling dirs
    PKG_VERSION="${PKG_VERSION}"
  fi

  PATCH_LOG="${ADM_LOGS}/patch-${PKG_NAME}-${PKG_VERSION}-${TS}.log"
  touch "${PATCH_LOG}" 2>/dev/null || true
  log_info "Patch init: pkg=${PKG_NAME} dir=${PKG_DIR} log=${PATCH_LOG}"
  ui_section_end_ok "Inicialização"
}

patch_list() {
  detect_patches
  if (( ${#PATCH_LIST[@]} == 0 )); then
    ui_info "Nenhum patch encontrado em ${PKG_DIR}/patch{,es}"
    return 0
  fi
  ui_section_start "Patches detectados"
  printf "Patches encontrados (%d):\n" "${#PATCH_LIST[@]}"
  for p in "${PATCH_LIST[@]}"; do
    printf " - %s\n" "$(pb "$p")"
  done
  ui_section_end_ok "Listagem"
}

patch_apply_all() {
  detect_patches
  if (( ${#PATCH_LIST[@]} == 0 )); then
    ui_info "Nenhum patch para aplicar em ${PKG_DIR}"
    return 0
  fi

  ui_section_start "Aplicando patches em ${PKG_NAME}"
  safe_mkdir "$(dirname "${PATCH_HISTORY}")"
  local total=${#PATCH_LIST[@]}
  local applied=0
  local failed=0

  for p in "${PATCH_LIST[@]}"; do
    local name="$(pb "$p")"
    ui_section_start "Aplicando ${name}"
    log_info "Applying patch ${p} to ${PKG_DIR}"
    if apply_patch_file "$p" "$PKG_DIR" "${PATCH_LOG}"; then
      applied=$((applied+1))
      log_info "Patch aplicado: ${name}"
      record_patch_history "APPLY" "${PKG_NAME}" "${PKG_VERSION}" "${name}|OK"
      ui_section_end_ok "Patch ${name}"
    else
      failed=$((failed+1))
      log_error "Patch falhou: ${name} (ver ${PATCH_LOG})"
      record_patch_history "APPLY" "${PKG_NAME}" "${PKG_VERSION}" "${name}|FAILED"
      ui_section_end_fail "Patch ${name}"
      # check for rejects
      local rej
      rej=$(check_for_rejects "${PKG_DIR}" || echo 0)
      if [[ "$rej" -gt 0 ]]; then
        log_warn "Existem arquivos .rej/.orig em ${PKG_DIR} (count=${rej})"
      fi
      if [[ "${STRICT}" -eq 1 ]]; then
        log_error "Modo strict: abortando após falha em ${name}"
        ui_section_end_fail "Patching (abortado)"
        return 2
      fi
    fi
  done

  ui_section_start "Verificando rejects"
  local rej_final
  rej_final=$(check_for_rejects "${PKG_DIR}" || echo 0)
  if [[ "$rej_final" -gt 0 ]]; then
    log_warn "Ao todo ${rej_final} arquivos .rej/.orig encontrados (ver ${PATCH_LOG})"
  fi
  ui_section_end_ok "Verificação de rejects"

  log_info "Patching finalizado: total=${total} applied=${applied} failed=${failed}"
  # return code: 0 if none failed, 1 if partial failures
  if [[ "$failed" -gt 0 ]]; then
    return 1
  fi
  return 0
}

patch_verify() {
  detect_patches
  if (( ${#PATCH_LIST[@]} == 0 )); then
    ui_info "Nenhum patch para verificar"
    return 0
  fi
  ui_section_start "Verificando aplicação de patches"
  local failed=0
  for p in "${PATCH_LIST[@]}"; do
    local name="$(pb "$p")"
    # quick heuristic: check for .rej/.orig relative to patch name
    local rejcount
    rejcount=$(find "${PKG_DIR}" -type f \( -name '*.rej' -o -name '*.orig' \) -print0 2>/dev/null | xargs -0 -r echo | wc -w || echo 0)
    if [[ "$rejcount" -gt 0 ]]; then
      log_warn "Patches parecem ter problemas (rej/orig present): ${rejcount}"
      failed=1
      break
    fi
    # also inspect patch log for 'FAILED' strings
    if grep -qiE 'failed|reject|patching file .*FAILED' "${PATCH_LOG}" 2>/dev/null; then
      log_warn "Patch log contém indicações de falha (ver ${PATCH_LOG})"
      failed=1
      break
    fi
  done
  ui_section_end_ok "Verificação concluída"
  if [[ "$failed" -gt 0 ]]; then
    return 1
  fi
  return 0
}

patch_revert_all() {
  detect_patches
  if (( ${#PATCH_LIST[@]} == 0 )); then
    ui_info "Nenhum patch para reverter"
    return 0
  fi
  # revert in reverse order
  ui_section_start "Revertendo patches em ${PKG_NAME}"
  local total=${#PATCH_LIST[@]}
  local reverted=0
  local failed=0
  for (( idx=total-1; idx>=0; idx-- )); do
    local p="${PATCH_LIST[idx]}"
    local name="$(pb "$p")"
    ui_section_start "Revertendo ${name}"
    if revert_patch_file "$p" "$PKG_DIR" "${PATCH_LOG}"; then
      reverted=$((reverted+1))
      record_patch_history "REVERT" "${PKG_NAME}" "${PKG_VERSION}" "${name}|OK"
      ui_section_end_ok "Revert ${name}"
      log_info "Patch revertido: ${name}"
    else
      failed=$((failed+1))
      record_patch_history "REVERT" "${PKG_NAME}" "${PKG_VERSION}" "${name}|FAILED"
      ui_section_end_fail "Revert ${name}"
      log_error "Falha ao reverter patch: ${name} (ver ${PATCH_LOG})"
      if [[ "${STRICT}" -eq 1 ]]; then
        log_error "Modo strict: abortando revert após falha em ${name}"
        return 2
      fi
    fi
  done

  log_info "Revert finalizado: total=${total} reverted=${reverted} failed=${failed}"
  if [[ "$failed" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# -------------------------
# CLI parsing
# -------------------------
_usage() {
  cat <<EOF
patch.sh - apply package patches automatically (from package patch/ or patches/)
Usage:
  patch.sh --pkg <pkg_dir> [--apply|--revert|--verify|--list] [options]
Options:
  --pkg <pkg_dir>       Package directory (or package name under repo)
  --apply               Apply patches (default)
  --revert              Revert applied patches (reverse order)
  --verify              Verify patch application (checks for .rej/.orig and log)
  --list                List detected patches
  --strict              Abort on first patch failure
  --debug               Keep logs; do not clean; verbose
  --yes                 Non-interactive (auto confirm)
  --dry-run             Show what would be done without changing files
  --verbose             Extra stdout logging
  --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pkg) PKG_DIR="${2:-}"; shift 2 ;;
    --apply) ACTION="apply"; shift ;;
    --revert) ACTION="revert"; shift ;;
    --verify) ACTION="verify"; shift ;;
    --list) ACTION="list"; shift ;;
    --strict) STRICT=1; shift ;;
    --debug) DEBUG=1; VERBOSE=1; shift ;;
    --yes|-y) AUTO_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --help|-h) _usage; exit 0 ;;
    *) echo "Unknown arg: $1"; _usage; exit 2 ;;
  esac
done

# -------------------------
# Main
# -------------------------
if [[ -z "${PKG_DIR}" ]]; then
  log_error "Parâmetro --pkg obrigatório"
  _usage
  exit 2
fi

patch_init

case "${ACTION}" in
  list)
    patch_list
    exit 0
    ;;
  apply)
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log_info "DRY-RUN: não aplicando patches"
    fi
    if patch_apply_all; then
      ui_section_start "Resumo do patch"
      ui_info "Todos os patches aplicados com sucesso (ver ${PATCH_LOG})"
      ui_section_end_ok "Resumo"
      exit 0
    else
      ui_section_start "Resumo do patch"
      ui_info "Alguns patches falharam (ver ${PATCH_LOG})"
      ui_section_end_fail "Resumo"
      exit 1
    fi
    ;;
  verify)
    if patch_verify; then
      ui_info "Verificação OK"
      exit 0
    else
      ui_info "Verificação falhou - veja o log ${PATCH_LOG}"
      exit 1
    fi
    ;;
  revert)
    if [[ "${AUTO_YES}" -eq 0 ]]; then
      if ! confirm "Tem certeza que quer reverter todos os patches em ${PKG_NAME}?"; then
        ui_info "Reversão cancelada"
        exit 0
      fi
    fi
    if patch_revert_all; then
      ui_info "Reversão concluída"
      exit 0
    else
      ui_info "Reversão teve falhas - ver ${PATCH_LOG}"
      exit 1
    fi
    ;;
  *)
    log_error "Ação desconhecida: ${ACTION}"
    exit 2
    ;;
esac
