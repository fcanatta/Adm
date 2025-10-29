#!/usr/bin/env bash
# /usr/src/adm/scripts/clean.sh
# ADM Build System - clean utilities
# Safe, idempotent cleaning of build artifacts, logs, sources and orphaned packages.
# Usage: clean.sh [--check] [--light|--full] [--yes]
set -o errexit
set -o nounset
set -o pipefail

# ----------------------
# Environment bootstrap
# ----------------------
ADM_BASE="${ADM_BASE:-/usr/src/adm}"
ADM_SCRIPTS="${ADM_BASE}/scripts"
ADM_LOGS="${ADM_LOGS:-${ADM_BASE}/logs}"
ADM_REPO="${ADM_REPO:-${ADM_BASE}/repo}"
ADM_BUILD="${ADM_BUILD:-${ADM_BASE}/build}"
ADM_CACHE="${ADM_CACHE:-${ADM_BASE}/cache}"
ADM_DB="${ADM_DB:-${ADM_BASE}/db}"
CLEAN_LOG=""
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
CLEAN_LOG="${ADM_LOGS}/clean-${TIMESTAMP}.log"

# Try to source env/log/ui if present (non-fatal)
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

# Local logging wrappers (safe even if log.sh not loaded)
_log_info() {
  local msg="$*"
  printf "%s [INFO] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >>"$CLEAN_LOG" 2>/dev/null || true
  if [[ "${_LOG_PRESENT}" == "yes" && "$(type -t log_info 2>/dev/null)" == "function" ]]; then
    log_info "$msg"
  fi
}
_log_warn() {
  local msg="$*"
  printf "%s [WARN] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >>"$CLEAN_LOG" 2>/dev/null || true
  if [[ "${_LOG_PRESENT}" == "yes" && "$(type -t log_warn 2>/dev/null)" == "function" ]]; then
    log_warn "$msg"
  else
    printf "[WARN] %s\n" "$msg" >&2
  fi
}
_log_error() {
  local msg="$*"
  printf "%s [ERROR] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >>"$CLEAN_LOG" 2>/dev/null || true
  if [[ "${_LOG_PRESENT}" == "yes" && "$(type -t log_error 2>/dev/null)" == "function" ]]; then
    log_error "$msg"
  else
    printf "[ERROR] %s\n" "$msg" >&2
  fi
}
_ui_start() {
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_header 2>/dev/null)" == "function" ]]; then
    ui_header
  fi
}
_ui_section() {
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_section 2>/dev/null)" == "function" ]]; then
    ui_section "$1"
  else
    printf "[*] %s\n" "$1"
  fi
}
_ui_end_section() {
  local status=$1; shift
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_end_section 2>/dev/null)" == "function" ]]; then
    ui_end_section "$status" "$@"
  else
    if [[ "$status" -eq 0 ]]; then
      printf "[✔] %s... concluído\n" "$*"
    else
      printf "[✖] %s... falhou\n" "$*"
    fi
  fi
}
_ui_info() {
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_info 2>/dev/null)" == "function" ]]; then
    ui_info "$*"
  else
    printf "[i] %s\n" "$*"
  fi
}

# ----------------------
# Options / state
# ----------------------
DRY_RUN=0
MODE="light"    # light | full
AUTO_YES=0
# stats
FILES_REMOVED=0
BYTES_FREED=0

# safe rm wrapper (only operates under ADM_BASE or /tmp fallback)
_safe_rm() {
  local path="$1"
  if [[ -z "$path" ]]; then return 0; fi
  # Resolve absolute path
  local abs
  abs="$(readlink -f "$path" 2>/dev/null || printf "%s" "$path")"
  # safety: only remove within ADM_BASE or /tmp/adm-fallback
  case "$abs" in
    "$ADM_BASE"/*|/tmp/adm-fallback/*)
      if [[ $DRY_RUN -eq 1 ]]; then
        _log_info "DRY-RUN remove $abs"
      else
        if [[ -d "$abs" ]]; then
          local before
          before=$(du -sb "$abs" 2>/dev/null | awk '{print $1}' || echo 0)
          rm -rf "$abs"
          local after=0
          FILES_REMOVED=$((FILES_REMOVED + $(find "$abs" -type f 2>/dev/null | wc -l) )) || true
          BYTES_FREED=$((BYTES_FREED + before - after))
          _log_info "Removed directory $abs (approx freed ${before} bytes)"
        elif [[ -f "$abs" ]]; then
          local sz
          sz=$(stat -c%s "$abs" 2>/dev/null || echo 0)
          rm -f "$abs"
          FILES_REMOVED=$((FILES_REMOVED + 1))
          BYTES_FREED=$((BYTES_FREED + sz))
          _log_info "Removed file $abs (freed ${sz} bytes)"
        fi
      fi
      ;;
    *)
      _log_warn "Refusing to remove outside ADM_BASE: $abs"
      ;;
  esac
}

# ----------------------
# clean_init - ensure dirs and logfile
# ----------------------
clean_init() {
  mkdir -p "$ADM_LOGS" "$ADM_BUILD" "$ADM_CACHE" "$ADM_REPO" "$ADM_DB" 2>/dev/null || true
  touch "$CLEAN_LOG" 2>/dev/null || true
  chmod 0644 "$CLEAN_LOG" 2>/dev/null || true
  _log_info "clean_init: started (mode=${MODE}, dry_run=${DRY_RUN})"
  _ui_start
}

# ----------------------
# clean_temp - remove temp build dirs
# ----------------------
clean_temp() {
  _ui_section "Limpando temporários"
  # patterns to consider
  local patterns=( "${ADM_BUILD}/tmp" "${ADM_BUILD}/.tmp*" "/tmp/build-*" "${ADM_CACHE}/tmp" "${ADM_CACHE}/.tmp*" )
  for p in "${patterns[@]}"; do
    # expand globs safely
    for candidate in $(ls -d $p 2>/dev/null || true); do
      _safe_rm "$candidate"
    done
  done
  _ui_end_section 0 "Limpeza de temporários"
}

# ----------------------
# clean_logs - rotate/clean logs by age/size
# ----------------------
clean_logs() {
  _ui_section "Limpando logs antigos"
  local age_days=7
  local size_limit=$((50 * 1024 * 1024)) # 50 MB

  # delete logs older than age_days
  if [[ $DRY_RUN -eq 1 ]]; then
    _log_info "DRY-RUN: would remove logs older than ${age_days}d in $ADM_LOGS"
  else
    find "$ADM_LOGS" -maxdepth 1 -type f -mtime +"${age_days}" -name '*.log' -print0 2>/dev/null | while IFS= read -r -d '' lf; do
      _safe_rm "$lf"
    done
  fi

  # remove logs bigger than size_limit (compress older first, then remove)
  if [[ $DRY_RUN -eq 1 ]]; then
    _log_info "DRY-RUN: would compress or remove logs > ${size_limit} bytes"
  else
    # compress logs > 5MB older than 1 day
    find "$ADM_LOGS" -type f -name '*.log' -size +5M -mtime +1 -print0 2>/dev/null | xargs -0 -r gzip -9 2>/dev/null || true
    # remove any compressed logs > 500MB (safety)
    find "$ADM_LOGS" -type f -name '*.gz' -size +500M -print0 2>/dev/null | xargs -0 -r rm -f 2>/dev/null || true
  fi

  _ui_end_section 0 "Limpeza de logs finalizada"
}

# ----------------------
# clean_sources - remove cached sources not referenced
# ----------------------
clean_sources() {
  _ui_section "Limpando fontes/caches não referenciados"
  # Keep sources referenced by repo (list all URLs or files referenced in repo)
  # Strategy: keep files referenced in repo (cache or repo/source). Remove others in ADM_CACHE
  local keep_patterns=()
  # gather filenames referenced under repo/source and repo/*
  if [[ -d "${ADM_REPO}" ]]; then
    # find archive files under repo/source
    while IFS= read -r f; do
      keep_patterns+=("$f")
    done < <(find "${ADM_REPO}/source" -type f -print 2>/dev/null || true)
  fi

  # iterate cache and remove files not in keep_patterns
  if [[ -d "${ADM_CACHE}" ]]; then
    # build a temp file listing keep basenames
    local tmpkeep
    tmpkeep="$(mktemp)"
    for kp in "${keep_patterns[@]}"; do
      basename "$kp" >>"$tmpkeep"
    done
    # remove cache files not matching
    while IFS= read -r cf; do
      local base
      base="$(basename "$cf")"
      if ! grep -Fxq "$base" "$tmpkeep" 2>/dev/null; then
        _safe_rm "$cf"
      fi
    done < <(find "${ADM_CACHE}" -type f -print 2>/dev/null || true)
    rm -f "$tmpkeep"
  fi

  _ui_end_section 0 "Limpeza de fontes concluída"
}

# ----------------------
# helper: build dependency reverse map
# ----------------------
_build_reverse_deps() {
  # produce a list: for each package in repo, map dependency -> package
  # Output format: depname|packagename
  local repo="${ADM_REPO}"
  if [[ ! -d "$repo" ]]; then return 0; fi
  # search build.conf files (simple parsing: lines starting with DEPEND=)
  find "$repo" -mindepth 2 -maxdepth 3 -type f -name 'build.conf' -print0 2>/dev/null | while IFS= read -r -d '' bf; do
    local pkgdir
    pkgdir="$(dirname "$bf")"
    local pkgname
    pkgname="$(basename "$pkgdir")"
    # read DEPEND line
    local depline
    depline="$(grep -E '^DEPEND=' "$bf" 2>/dev/null || true)"
    if [[ -n "$depline" ]]; then
      # strip DEPEND= and quotes
      depline="${depline#DEPEND=}"
      depline="${depline%\"}"
      depline="${depline#\"}"
      # split by comma
      IFS=',' read -r -a depsarr <<<"$depline"
      for d in "${depsarr[@]}"; do
        d="$(echo "$d" | tr -d '[:space:]')"
        if [[ -n "$d" ]]; then
          printf '%s|%s\n' "$d" "$pkgname"
        fi
      done
    fi
  done
}

# ----------------------
# clean_orphans - detect and optionally remove orphan packages
# ----------------------
clean_orphans() {
  _ui_section "Detectando órfãos"
  # Expect installed list at ADM_DB/installed.db (one pkg per line: name[:version])
  local installed_file="${ADM_DB}/installed.db"
  if [[ ! -f "$installed_file" ]]; then
    _log_warn "Arquivo de instalação não encontrado: $installed_file (nenhum órfão detectado)"
    _ui_end_section 0 "Detecção de órfãos"
    return 0
  fi

  # build map of reverse deps
  local revtmp
  revtmp="$(mktemp)"
  _build_reverse_deps >"$revtmp" || true

  # read installed packages
  local orphans=()
  while IFS= read -r line; do
    local pkg
    pkg="${line%%[: ]*}"
    # check if any package depends on pkg
    if ! grep -qE "^${pkg}\|" "$revtmp" 2>/dev/null; then
      # no reverse deps -> candidate orphan
      orphans+=("$pkg")
    fi
  done < <(sed -e '/^\s*#/d' -e '/^\s*$/d' "$installed_file" 2>/dev/null || true)

  rm -f "$revtmp"

  if [[ "${#orphans[@]}" -eq 0 ]]; then
    _log_info "Nenhum órfão detectado."
    _ui_end_section 0 "Detecção de órfãos"
    return 0
  fi

  _log_info "Órfãos detectados: ${orphans[*]}"
  _ui_info "Órfãos detectados: ${orphans[*]}"

  if [[ $DRY_RUN -eq 1 ]]; then
    _log_info "DRY-RUN: não serão removidos órfãos."
    _ui_end_section 0 "Detecção de órfãos (DRY-RUN)"
    return 0
  fi

  # confirmation unless AUTO_YES
  if [[ $AUTO_YES -ne 1 ]]; then
    printf "Remover órfãos? [y/N]: "
    read -r ans
    case "$ans" in
      y|Y) ;;
      *) _ui_end_section 0 "Remoção de órfãos cancelada"; return 0 ;;
    esac
  fi

  # perform removal: try to call uninstall.sh if exists, else remove files under repo/install manifests
  for p in "${orphans[@]}"; do
    if [[ -x "${ADM_SCRIPTS}/uninstall.sh" ]]; then
      _log_info "Invocando uninstall.sh para $p"
      if "${ADM_SCRIPTS}/uninstall.sh" "$p" >>"$CLEAN_LOG" 2>&1; then
        _log_info "Uninstalled orphan: $p"
      else
        _log_warn "uninstall.sh failed for $p, attempting manual cleanup"
        # manual attempt: remove repo/build/source for the package
        _safe_rm "${ADM_REPO}/${p}"
        _safe_rm "${ADM_BUILD}/${p}"
      fi
    else
      _log_info "No uninstall.sh found; removing repo/build entries for $p"
      _safe_rm "${ADM_REPO}/${p}"
      _safe_rm "${ADM_BUILD}/${p}"
    fi
  done

  _ui_end_section 0 "Remoção de órfãos concluída"
}

# ----------------------
# clean_all - orchestrator
# ----------------------
clean_all() {
  clean_init
  case "$MODE" in
    light)
      clean_temp
      clean_logs
      ;;
    full)
      clean_temp
      clean_logs
      clean_sources
      clean_orphans
      ;;
    *)
      clean_temp
      clean_logs
      ;;
  esac
  clean_summary
}

# ----------------------
# clean_summary - show stats
# ----------------------
clean_summary() {
  local freed_human
  if command -v numfmt >/dev/null 2>&1; then
    freed_human=$(numfmt --to=iec --suffix=B --format="%.1f" "$BYTES_FREED" 2>/dev/null || printf "%s" "${BYTES_FREED}")
  else
    # rough
    freed_human="${BYTES_FREED} bytes"
  fi

  _log_info "clean_summary: files_removed=${FILES_REMOVED} bytes_freed=${BYTES_FREED}"
  echo
  printf "╔══════════════════════════════════════════════════════════════════════╗\n"
  printf "║  Limpeza concluída                                                   ║\n"
  printf "║  Arquivos removidos: %s\n" "${FILES_REMOVED}"
  printf "║  Espaço liberado: %s\n" "${freed_human}"
  printf "║  Tempo: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "║  Log: %s\n" "${CLEAN_LOG}"
  printf "╚══════════════════════════════════════════════════════════════════════╝\n"
}

# ----------------------
# CLI parsing
# ----------------------
_print_usage() {
  cat <<'EOF'
clean.sh - safe cleaning utilities for ADM Build System

Usage:
  clean.sh [--check] [--light|--full] [--yes]
Options:
  --check     Dry-run: show what would be removed
  --light     Remove only temporary build dirs and old logs (default)
  --full      Full cleanup: temp, logs, sources not referenced, orphan packages
  --yes       Auto-confirm destructive operations
  --help      Show this help
EOF
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|-n)
      DRY_RUN=1
      shift
      ;;
    --full)
      MODE="full"
      shift
      ;;
    --light)
      MODE="light"
      shift
      ;;
    --yes|-y)
      AUTO_YES=1
      shift
      ;;
    --help|-h)
      _print_usage
      exit 0
      ;;
    *)
      printf "Unknown arg: %s\n" "$1" >&2
      _print_usage
      exit 2
      ;;
  esac
done

# ensure CLEAN_LOG exists
mkdir -p "$ADM_LOGS" 2>/dev/null || true
touch "$CLEAN_LOG" 2>/dev/null || true

# Execute
clean_all

exit 0
