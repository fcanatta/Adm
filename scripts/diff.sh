#!/usr/bin/env bash
# /usr/src/adm/scripts/diff.sh
# ADM Build System - diff & patch utilities
# Compares source vs build, generates patches, applies patches, summary.
# Requirements: bash, diff, patch, mkdir, gzip (optional)
set -o errexit
set -o nounset
set -o pipefail

# --- Load environment if possible (no failure if not present) ---
if [[ -r "/usr/src/adm/scripts/env.sh" ]]; then
  # shellcheck disable=SC1091
  source /usr/src/adm/scripts/env.sh || true
fi

# Attempt to load log/ui helpers if present (non-fatal)
_LOG_PRESENT=no
_UI_PRESENT=no
if [[ -r "${ADM_BASE:-/usr/src/adm}/scripts/log.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_BASE:-/usr/src/adm}/scripts/log.sh" || true
  _LOG_PRESENT=yes
fi
if [[ -r "${ADM_BASE:-/usr/src/adm}/scripts/ui.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_BASE:-/usr/src/adm}/scripts/ui.sh" || true
  _UI_PRESENT=yes
fi

# Local helpers that use log_*/ui_* if available
_log_info() {
  if [[ "${_LOG_PRESENT}" == "yes" && "$(type -t log_info 2>/dev/null)" == "function" ]]; then
    log_info "$*"
  else
    printf "[INFO] %s\n" "$*" >&2
  fi
}
_log_warn() {
  if [[ "${_LOG_PRESENT}" == "yes" && "$(type -t log_warn 2>/dev/null)" == "function" ]]; then
    log_warn "$*"
  else
    printf "[WARN] %s\n" "$*" >&2
  fi
}
_log_error() {
  if [[ "${_LOG_PRESENT}" == "yes" && "$(type -t log_error 2>/dev/null)" == "function" ]]; then
    log_error "$*"
  else
    printf "[ERROR] %s\n" "$*" >&2
  fi
}
_ui_section_start() {
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_section 2>/dev/null)" == "function" ]]; then
    ui_section "$1"
  else
    _log_info "$1"
  fi
}
_ui_section_end() {
  local status=${1:-0}; shift
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_end_section 2>/dev/null)" == "function" ]]; then
    ui_end_section "$status" "$*"
  else
    if [[ "$status" -eq 0 ]]; then
      _log_info "$* - concluído"
    else
      _log_error "$* - falhou"
    fi
  fi
}

# ----------------------------
# Defaults and derived paths
# ----------------------------
ADM_BASE="${ADM_BASE:-/usr/src/adm}"
ADM_REPO="${ADM_REPO:-$ADM_BASE/repo}"
ADM_PKG_NAME="${ADM_PKG_NAME:-unknown}"
ADM_PKG_VERSION="${ADM_PKG_VERSION:-unknown}"
ADM_PATCHES_DIR="${ADM_REPO}/patches/${ADM_PKG_NAME}"
ADM_SOURCE_DIR="${ADM_REPO}/source/${ADM_PKG_NAME}-${ADM_PKG_VERSION}"
ADM_BUILD_DIR="${ADM_REPO}/build/${ADM_PKG_NAME}-${ADM_PKG_VERSION}"
ADM_DIFF_TMP="${ADM_BASE}/build/.diff_tmp"
ADM_DIFF_OUT="${ADM_BASE}/build/.diff_out"
mkdir -p "$ADM_DIFF_TMP" "$ADM_DIFF_OUT" 2>/dev/null || true

# ----------------------------
# Ignore patterns for diff (regex/globs)
# ----------------------------
_default_ignore_patterns=(
  '*.o' '*.a' '*.so' '*.so.*' '*.class' '*.pyc' '*.pyo' '*.o.*' '*/.git/*' '*/.hg/*'
  '*.log' '*.tmp' '*.swp' 'build/' 'bin/' 'obj/' '*.exe' '*.dll'
)

# Build a --exclude args list for diff
_build_exclude_args() {
  local -n arr=$1
  local args=()
  for p in "${arr[@]}"; do
    args+=( "--exclude=$p" )
  done
  printf '%s\n' "${args[@]}"
}

# ----------------------------
# Ensure standard directories exist
# ----------------------------
diff_init() {
  _ui_section_start "Preparando estrutura para diff"
  mkdir -p "$ADM_REPO" "$ADM_PATCHES_DIR" "$ADM_SOURCE_DIR" "$ADM_BUILD_DIR" "$ADM_DIFF_TMP" "$ADM_DIFF_OUT" 2>/dev/null || {
    _log_warn "Falha ao criar diretórios necessários (tentar permissões)."
  }
  _log_info "Diretórios garantidos: repo, patches, source, build"
  _ui_section_end 0 "Preparação da estrutura"
}

# ----------------------------
# Generate diff between source and build
# Produces unified patch into a temp file (uncompressed)
# ----------------------------
diff_check_changes() {
  local ignore_patterns=("${_default_ignore_patterns[@]}")
  local excludes=()
  for p in "${ignore_patterns[@]}"; do
    excludes+=( "--exclude=$p" )
  done

  if [[ ! -d "$ADM_SOURCE_DIR" ]]; then
    _log_warn "Diretório de source inexistente: $ADM_SOURCE_DIR"
    return 2
  fi
  if [[ ! -d "$ADM_BUILD_DIR" ]]; then
    _log_warn "Diretório de build inexistente: $ADM_BUILD_DIR"
    return 2
  fi

  local outpatch="${ADM_DIFF_TMP}/${ADM_PKG_NAME}-${ADM_PKG_VERSION}.patch"
  rm -f "$outpatch" 2>/dev/null || true

  _ui_section_start "Comparando source ↔ build"
  # Use diff -Naur: new files, deleted files and context unified diff
  # Run from repo root to keep relative paths stable
  pushd "$ADM_REPO" >/dev/null 2>&1 || return 1
  # Build command args safely
  local diff_cmd
  diff_cmd=(diff -Naur "${excludes[@]}" "source/${ADM_PKG_NAME}-${ADM_PKG_VERSION}" "build/${ADM_PKG_NAME}-${ADM_PKG_VERSION}")
  # Execute and capture status
  if "${diff_cmd[@]}" >"$outpatch" 2>&1; then
    # no differences
    rm -f "$outpatch"
    popd >/dev/null 2>&1 || true
    _ui_section_end 0 "Comparação concluída (sem alterações)"
    return 0
  else
    # diff returns non-zero when differences exist; ensure outpatch not empty
    if [[ -s "$outpatch" ]]; then
      _log_info "Diferenças detectadas: patch preliminar em $outpatch"
      _ui_section_end 0 "Comparação concluída (diferenças detectadas)"
      popd >/dev/null 2>&1 || true
      # leave outpatch for patch generation
      echo "$outpatch"
      return 0
    else
      popd >/dev/null 2>&1 || true
      _ui_section_end 1 "Comparação falhou (output vazio)"
      return 3
    fi
  fi
}

# ----------------------------
# Clean up extraneous noise in patch:
# remove timestamps from binary files headers, filter out /dev/null lines noise if any
# This keeps patch tidy.
# ----------------------------
_diff_sanitize_patch() {
  local in="$1"
  local out="$2"
  # Simple sanitation: remove trailing whitespaces on lines and ensure LF endings
  sed -e 's/[[:space:]]\+$//' "$in" >"$out"
  return 0
}

# ----------------------------
# Generate final patch file into ADM_PATCHES_DIR, gzipped backup optional
# ----------------------------
diff_generate_patch() {
  local prelim_patch_path="$1"
  if [[ -z "$prelim_patch_path" ]]; then
    _log_error "diff_generate_patch precisa do caminho do patch preliminar"
    return 1
  fi
  if [[ ! -s "$prelim_patch_path" ]]; then
    _log_warn "Patch preliminar vazio: $prelim_patch_path"
    return 2
  fi

  _ui_section_start "Gerando patch final"
  mkdir -p "$ADM_PATCHES_DIR" 2>/dev/null || true
  local stamp
  stamp="$(date +%Y%m%d_%H%M%S)"
  local patch_name="${ADM_PKG_NAME}-${ADM_PKG_VERSION}-${stamp}.patch"
  local patch_path="${ADM_PATCHES_DIR}/${patch_name}"

  # sanitize then write header
  {
    printf "/* ADM PATCH\n"
    printf " * Package: %s\n" "${ADM_PKG_NAME}"
    printf " * Version: %s\n" "${ADM_PKG_VERSION}"
    printf " * Date: %s\n" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    printf " * Profile: %s\n" "${ADM_PROFILE:-unknown}"
    printf " */\n\n"
    cat "$prelim_patch_path"
  } >"$patch_path"

  # sanitize in place (remove trailing spaces)
  _diff_sanitize_patch "$patch_path" "${patch_path}.tmp" && mv "${patch_path}.tmp" "$patch_path" || true

  # record in log
  _log_info "Patch final gerado: $patch_path"
  # optional gzip rotate older patches (keep readable copy too)
  if command -v gzip >/dev/null 2>&1; then
    # rotate older than 60 days (non-blocking)
    find "$ADM_PATCHES_DIR" -name '*.patch' -type f -mtime +60 -print0 2>/dev/null | xargs -0 -r gzip -9 2>/dev/null || true
  fi

  _ui_section_end 0 "Patch gerado"
  printf "%s\n" "$patch_path"
  return 0
}

# ----------------------------
# Apply patch(s) found in patches dir to source (in order)
# ----------------------------
diff_apply_patch() {
  local patches_dir="${1:-$ADM_PATCHES_DIR}"
  if [[ ! -d "$patches_dir" ]]; then
    _log_warn "Patches dir inexistente: $patches_dir"
    return 2
  fi

  _ui_section_start "Aplicando patches em source"
  local applied=0
  # iterate patches sorted by name (timestamp in filename ensures order)
  mapfile -t patches < <(ls -1 "${patches_dir}"/*.patch 2>/dev/null | sort || true)
  for p in "${patches[@]}"; do
    [[ -f "$p" ]] || continue
    _log_info "Aplicando patch: $p"
    # attempt dry-run first
    if patch -p0 --dry-run -s -f -F3 <"$p" >/dev/null 2>&1; then
      if patch -p0 -s -f -F3 <"$p" >>"${ADM_LOGFILE:-/dev/null}" 2>&1; then
        _log_info "Patch aplicado: $p"
        applied=$((applied + 1))
      else
        _log_error "Falha ao aplicar patch (exec): $p"
        _ui_section_end 1 "Aplicação de patches (falha)"
        return 3
      fi
    else
      _log_warn "Patch com conflito (dry-run falhou): $p"
      _ui_section_end 1 "Aplicação de patches (conflito)"
      return 4
    fi
  done

  _ui_section_end 0 "Aplicação de patches finalizada"
  _log_info "Total patches aplicados: $applied"
  return 0
}

# ----------------------------
# Summary reporting: prints succinct information to screen and log
# ----------------------------
diff_summary() {
  local patch_path="${1:-}"
  if [[ -z "$patch_path" ]]; then
    _log_info "diff_summary: nenhuma alteração detectada para $ADM_PKG_NAME-$ADM_PKG_VERSION"
    if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_info 2>/dev/null)" == "function" ]]; then
      ui_info "Nenhuma modificação detectada para ${ADM_PKG_NAME}-${ADM_PKG_VERSION}"
    else
      printf "Nenhuma modificação detectada for %s-%s\n" "$ADM_PKG_NAME" "$ADM_PKG_VERSION"
    fi
    return 0
  fi

  # show summary top lines and basic stats
  local changed_files
  changed_files=$(grep -E '^\+\+\+ |^\-\-\- ' "$patch_path" | sed -E 's/^[+\-]{3} (a|b)?\///' | sort -u | wc -l || echo 0)
  _log_info "Patch criado: $patch_path (arquivos alterados: $changed_files)"
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_info 2>/dev/null)" == "function" ]]; then
    ui_info "Patch salvo: ${patch_path} (arquivos alterados: ${changed_files})"
  else
    printf "Patch salvo: %s (arquivos alterados: %s)\n" "$patch_path" "$changed_files"
  fi
}

# ----------------------------
# CLI wrapper for direct execution
# ----------------------------
_diff_usage() {
  cat <<'EOF'
diff.sh - utilitários de comparação e patch
Usage:
  diff.sh init
  diff.sh check    -> performs comparison, outputs prelim patch path if diff exists
  diff.sh generate <prelim_patch_path> -> sanitize and move to repo/patches
  diff.sh apply [patches_dir] -> apply patches to source
  diff.sh summary <patch_path|empty> -> print summary
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    init) diff_init ;;
    check)
      diff_init
      out=$(diff_check_changes) || true
      # if function printed path, capture it (we echo path on success)
      if [[ -n "$out" ]]; then
        printf "%s\n" "$out"
      fi
      ;;
    generate)
      if [[ -z "${2:-}" ]]; then
        _log_error "Uso: diff.sh generate <prelim_patch_path>"
        exit 2
      fi
      diff_generate_patch "$2"
      ;;
    apply)
      diff_apply_patch "${2:-}"
      ;;
    summary)
      diff_summary "${2:-}"
      ;;
    *)
      _diff_usage
      exit 1
      ;;
  esac
  exit 0
fi

# Export functions for sourcing
export -f diff_init diff_check_changes diff_generate_patch diff_apply_patch diff_summary
