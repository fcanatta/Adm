#!/usr/bin/env bash
# /usr/src/adm/scripts/integrity.sh
# ADM Build System - integrity checks
# - dynamic verification of scripts, sources and repo metadata (build.conf)
# - supports --check (default), --fix (safe corrections), scoped checks
# - integrates with env.sh, log.sh, ui.sh when present
set -o errexit
set -o nounset
set -o pipefail

# -----------------------
# Defaults / Environment
# -----------------------
ADM_BASE="${ADM_BASE:-/usr/src/adm}"
ADM_SCRIPTS="${ADM_SCRIPTS:-${ADM_BASE}/scripts}"
ADM_REPO="${ADM_REPO:-${ADM_BASE}/repo}"
ADM_CACHE="${ADM_CACHE:-${ADM_BASE}/cache}"
ADM_BUILD="${ADM_BUILD:-${ADM_BASE}/build}"
ADM_LOGS="${ADM_LOGS:-${ADM_BASE}/logs}"
ADM_DB="${ADM_DB:-${ADM_BASE}/db}"

TS="$(date '+%Y%m%d_%H%M%S')"
INTEGRITY_LOG="${ADM_LOGS}/integrity-${TS}.log"

# CLI defaults
MODE_CHECK=1     # default: check-only
MODE_FIX=0
SCOPE_ALL=1
SCOPE_SCRIPTS=0
SCOPE_SOURCES=0
SCOPE_REPO=0
AUTO_YES=0
VERBOSE=0

# helper flags / counts
_EXIT_CODE=0   # 0 OK, 1 warnings, 2 failures
_WARNINGS=0
_ERRORS=0
_MODIFIED_SCRIPTS=()

# Try source env/log/ui if available (non-fatal)
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

# Local logging wrappers (use log.sh if present)
_log_ts() { printf "%s" "$(date '+%Y-%m-%d %H:%M:%S')"; }
_log_info() {
  local m="$*"
  printf "%s [INFO] %s\n" "$(_log_ts)" "$m" >>"$INTEGRITY_LOG" 2>/dev/null || true
  if [[ "${_LOG_PRESENT}" == "yes" && "$(type -t log_info 2>/dev/null)" == "function" ]]; then
    log_info "$m"
  fi
}
_log_warn() {
  local m="$*"
  _WARNINGS=$(( _WARNINGS + 1 ))
  printf "%s [WARN] %s\n" "$(_log_ts)" "$m" >>"$INTEGRITY_LOG" 2>/dev/null || true
  if [[ "${_LOG_PRESENT}" == "yes" && "$(type -t log_warn 2>/dev/null)" == "function" ]]; then
    log_warn "$m"
  else
    printf "[WARN] %s\n" "$m" >&2
  fi
}
_log_error() {
  local m="$*"
  _ERRORS=$(( _ERRORS + 1 ))
  printf "%s [ERROR] %s\n" "$(_log_ts)" "$m" >>"$INTEGRITY_LOG" 2>/dev/null || true
  if [[ "${_LOG_PRESENT}" == "yes" && "$(type -t log_error 2>/dev/null)" == "function" ]]; then
    log_error "$m"
  else
    printf "[ERROR] %s\n" "$m" >&2
  fi
}

_ui_section_start() {
  local title="$1"
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_section 2>/dev/null)" == "function" ]]; then
    ui_section "$title"
  else
    printf "[*] %s\n" "$title"
  fi
}
_ui_section_end() {
  local status=${1:-0}
  local title="$2"
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_end_section 2>/dev/null)" == "function" ]]; then
    ui_end_section "$status" "$title"
  else
    if [[ "$status" -eq 0 ]]; then
      printf "[✔] %s... concluído\n" "$title"
    else
      printf "[✖] %s... falhou\n" "$title"
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

# -----------------------
# Helpers
# -----------------------
ensure_dirs() {
  mkdir -p "$ADM_LOGS" "$ADM_REPO" "$ADM_CACHE" "$ADM_SCRIPTS" "$ADM_DB" 2>/dev/null || true
  touch "$INTEGRITY_LOG" 2>/dev/null || true
  chmod 0644 "$INTEGRITY_LOG" 2>/dev/null || true
  _log_info "Integrity check started (log: $INTEGRITY_LOG)"
}

# safe parse simple build.conf (KEY=VALUE)
# returns 0 and prints variables as KEY=VALUE lines
parse_build_conf() {
  local file="$1"
  if [[ ! -r "$file" ]]; then
    return 1
  fi
  # read only simple KEY=VALUE, ignore comments
  awk -F= '
    /^[[:space:]]*#/ {next}
    NF>=2 {
      key=$1; sub(/^[[:space:]]*/,"",key); sub(/[[:space:]]*$/,"",key);
      $1=""; sub(/^=/,"",$0);
      val=$0; gsub(/^[[:space:]]*/,"",val); gsub(/[[:space:]]*$/,"",val);
      print key"="val
    }' "$file"
  return 0
}

# compute sha256 of a file; returns string or empty on failure
sha256_of() {
  local f="$1"
  if [[ -f "$f" ]]; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  else
    printf ""
  fi
}

# compare with .sha256 file if present (expects "SHA  filename" or "SHA")
check_sha_file() {
  local shafile="$1"
  local target="$2"
  if [[ ! -r "$shafile" ]]; then
    return 2
  fi
  # support both "sha filename" and bare sha
  local expected
  expected="$(awk '{print $1; exit}' "$shafile" 2>/dev/null || true)"
  if [[ -z "$expected" ]]; then
    return 2
  fi
  local actual
  actual="$(sha256_of "$target")"
  if [[ -z "$actual" ]]; then
    return 3
  fi
  if [[ "$actual" == "$expected" ]]; then
    return 0
  else
    return 1
  fi
}

# ask confirmation
confirm() {
  if [[ $AUTO_YES -eq 1 ]]; then
    return 0
  fi
  printf "%s [y/N]: " "$1"
  read -r ans
  case "$ans" in
    y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

# -----------------------
# integrity: scripts
# - dynamically list *.sh in ADM_SCRIPTS
# - check existence, exec permission, optional sha file in ADM_DB/scripts.sha256
# -----------------------
integrity_scripts() {
  _ui_section_start "Verificando scripts em ${ADM_SCRIPTS}"
  local sha_db="${ADM_DB}/scripts.sha256"
  local have_sha_db=0
  if [[ -r "$sha_db" ]]; then
    have_sha_db=1
    _log_info "Scripts hash db found: $sha_db"
  fi

  local found_any=0
  shopt -s nullglob
  for script in "$ADM_SCRIPTS"/*.sh "$ADM_SCRIPTS"/*/*.sh; do
    # iterate only files
    [[ -f "$script" ]] || continue
    found_any=1
    local rel="${script#$ADM_BASE/}"
    _log_info "Checking script: $script"
    # exist & executable?
    if [[ ! -x "$script" ]]; then
      _log_warn "Script not executable: $script"
      if [[ $MODE_FIX -eq 1 ]]; then
        if [[ $AUTO_YES -eq 1 ]] || confirm "Definir exec permission para $script?"; then
          chmod 0755 "$script" 2>/dev/null || _log_warn "Falha chmod $script"
          _log_info "Permissão ajustada: $script"
        fi
      fi
    fi
    # compute sha
    local sha
    sha="$(sha256_of "$script")"
    if [[ -z "$sha" ]]; then
      _log_error "Não foi possível calcular sha256: $script"
      _ERRORS=$(( _ERRORS + 1 ))
      continue
    fi
    # compare with sha db if exists
    if [[ $have_sha_db -eq 1 ]]; then
      # find entry
      local expected
      expected="$(grep -E "^[0-9a-fA-F]{64}" "$sha_db" 2>/dev/null | awk -v s="$script" '{
         # try match by filename at end or second field
         if ($2==s || index($0,s)) { print $1; exit }
      }')"
      if [[ -n "$expected" ]]; then
        if [[ "$expected" != "$sha" ]]; then
          _log_warn "Script modificado: $script"
          _MODIFIED_SCRIPTS+=("$script")
          _WARNINGS=$(( _WARNINGS + 1 ))
          _EXIT_CODE=1
        else
          _log_info "Script OK: $script"
        fi
      else
        _log_warn "Hash não encontrado no DB para $script"
      fi
    else
      _log_info "Script hash: $sha"
    fi
  done
  shopt -u nullglob

  if [[ "$found_any" -eq 0 ]]; then
    _log_warn "Nenhum script encontrado em $ADM_SCRIPTS"
  fi

  _ui_section_end 0 "Verificação de scripts"
}

# -----------------------
# integrity: sources
# - iterate packages under ADM_REPO/*/*/build.conf
# - for each, parse NAME VERSION SOURCE and check file in ADM_CACHE or ADM_REPO/source/
# - verify sha if .sha256 present or report sha
# -----------------------
integrity_sources() {
  _ui_section_start "Verificando fontes (sources) em cache/repo"
  local pkg_buildconf
  local any_ok=0
  # find all build.conf files under ADM_REPO (depth 2+)
  while IFS= read -r -d '' pkg_buildconf; do
    # ensure readable
    [[ -r "$pkg_buildconf" ]] || { _log_warn "build.conf não legível: $pkg_buildconf"; continue; }
    # parse build.conf for NAME and VERSION and URL/Source
    local NAME="" VERSION="" SOURCE=""
    while IFS= read -r line; do
      # strip comments and trim
      line="${line%%#*}"
      line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ -z "$line" ]] && continue
      if [[ "$line" =~ ^NAME= ]]; then NAME="${line#NAME=}"; NAME="${NAME%\"}"; NAME="${NAME#\"}"; fi
      if [[ "$line" =~ ^VERSION= ]]; then VERSION="${line#VERSION=}"; VERSION="${VERSION%\"}"; VERSION="${VERSION#\"}"; fi
      if [[ "$line" =~ ^URL=|^SOURCE= ]]; then SOURCE="${line#*=}"; SOURCE="${SOURCE%\"}"; SOURCE="${SOURCE#\"}"; fi
    done <"$pkg_buildconf"

    # fallback: if NAME/VERSION empty, try dirname
    if [[ -z "$NAME" ]]; then
      NAME="$(basename "$(dirname "$pkg_buildconf")")"
    fi
    if [[ -z "$VERSION" ]]; then
      # try to infer from filename in SOURCE
      VERSION="unknown"
    fi

    # resolve candidate filenames
    local candidate=""
    # expand typical patterns
    if [[ -n "$SOURCE" ]]; then
      # try expand $NAME $VERSION if present
      candidate="${SOURCE//\$NAME/$NAME}"
      candidate="${candidate//\$VERSION/$VERSION}"
      # basename
      candidate="$(basename "$candidate")"
    fi

    local found_file=""
    # check ADM_CACHE
    if [[ -n "$candidate" && -f "${ADM_CACHE}/${candidate}" ]]; then
      found_file="${ADM_CACHE}/${candidate}"
    fi
    # check ADM_REPO/source
    if [[ -z "$found_file" && -n "$candidate" && -f "${ADM_REPO}/source/${candidate}" ]]; then
      found_file="${ADM_REPO}/source/${candidate}"
    fi

    # if still empty, try any file under repo/source matching NAME or VERSION
    if [[ -z "$found_file" ]]; then
      # find files with NAME in basename
      local f
      f="$(find "${ADM_REPO}/source" -type f -iname "*${NAME}*" -print -quit 2>/dev/null || true)"
      if [[ -n "$f" ]]; then
        found_file="$f"
      fi
    fi

    if [[ -z "$found_file" ]]; then
      _log_warn "Fonte ausente para ${NAME}-${VERSION} (build.conf: ${pkg_buildconf})"
      _ERRORS=$(( _ERRORS + 1 ))
      _EXIT_CODE=2
      continue
    fi

    # if sha file exists adjacent or in same dir with .sha256
    local shafile=""
    if [[ -f "${found_file}.sha256" ]]; then
      shafile="${found_file}.sha256"
    else
      # also check repo/source/<name>.sha256
      local basef
      basef="$(basename "$found_file")"
      if [[ -f "${ADM_REPO}/source/${basef}.sha256" ]]; then
        shafile="${ADM_REPO}/source/${basef}.sha256"
      fi
    fi

    if [[ -n "$shafile" ]]; then
      if check_sha_file "$shafile" "$found_file"; then
        _log_info "Fonte OK: $found_file (sha ok)"
        any_ok=1
      else
        _log_warn "Checksum inválido ou ausente para $found_file"
        _EXIT_CODE=1
        _ERRORS=$(( _ERRORS + 1 ))
        if [[ $MODE_FIX -eq 1 ]]; then
          if [[ $AUTO_YES -eq 1 ]] || confirm "Atualizar .sha256 para $found_file com sha atual?"; then
            sha256_of "$found_file" >"${found_file}.sha256.tmp"
            sha256sum "$found_file" | awk '{print $1}' >"${found_file}.sha256"
            rm -f "${found_file}.sha256.tmp" 2>/dev/null || true
            _log_info "Arquivo .sha256 atualizado para $found_file"
          fi
        fi
      fi
    else
      # no shafile: report and optionally create if fix mode
      local actual_sha
      actual_sha="$(sha256_of "$found_file")"
      if [[ -n "$actual_sha" ]]; then
        _log_info "Fonte encontrada: $found_file (sha: ${actual_sha})"
        if [[ $MODE_FIX -eq 1 ]]; then
          if [[ $AUTO_YES -eq 1 ]] || confirm "Criar .sha256 para $found_file?"; then
            printf "%s  %s\n" "$actual_sha" "$(basename "$found_file")" >"${found_file}.sha256"
            _log_info "Criado ${found_file}.sha256"
          fi
        fi
      else
        _log_error "Não foi possível calcular SHA para $found_file"
        _EXIT_CODE=2
      fi
    fi
  done < <(find "$ADM_REPO" -type f -name 'build.conf' -print0 2>/dev/null)
  _ui_section_end 0 "Verificação de fontes"
}

# -----------------------
# integrity: repo metadata
# - validate build.conf presence and minimal fields
# -----------------------
integrity_repo() {
  _ui_section_start "Validando metadados do repositório (build.conf)"
  local any_missing=0
  while IFS= read -r -d '' bcf; do
    # check readable
    if [[ ! -r "$bcf" ]]; then
      _log_warn "build.conf não legível: $bcf"
      any_missing=1
      continue
    fi
    # check mandatory fields NAME and VERSION
    local has_name=0 has_version=0
    if grep -qE '^NAME=' "$bcf"; then has_name=1; fi
    if grep -qE '^VERSION=' "$bcf"; then has_version=1; fi
    if [[ $has_name -ne 1 || $has_version -ne 1 ]]; then
      _log_warn "build.conf incompleto (sem NAME/VERSION): $bcf"
      any_missing=1
    else
      _log_info "build.conf ok: $bcf"
    fi
    # check permissions
    if [[ ! -r "$bcf" ]]; then
      _log_warn "Permissões estranhas em $bcf"
    fi
  done < <(find "$ADM_REPO" -type f -name 'build.conf' -print0 2>/dev/null)

  if [[ $any_missing -ne 0 ]]; then
    _EXIT_CODE=1
  fi
  _ui_section_end 0 "Validação de metadados"
}

# -----------------------
# integrity: db checks
# - verify installed.db entries exist in repo and no duplicates
# -----------------------
integrity_db() {
  _ui_section_start "Verificando integridade do DB (installed.db)"
  local installed="${ADM_DB}/installed.db"
  if [[ ! -f "$installed" ]]; then
    _log_warn "installed.db ausente: $installed"
    _ui_section_end 0 "Verificação do DB"
    return 0
  fi

  # check duplicates
  local dup_count
  dup_count="$(awk '!/^#/ && NF {print $1}' "$installed" | sort | uniq -d | wc -l || echo 0)"
  if [[ "$dup_count" -gt 0 ]]; then
    _log_warn "installed.db contém duplicatas (count: $dup_count)"
    _EXIT_CODE=1
  fi

  # for each entry check exists in repo
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    local pkg="${line%%[: ]*}"
    # find build.conf for pkg
    if ! find "$ADM_REPO" -type f -name 'build.conf' -exec grep -H "^NAME=${pkg}\$" {} \; >/dev/null 2>&1; then
      _log_warn "installed.db references missing package in repo: $pkg"
      _EXIT_CODE=1
    fi
  done <"$installed"

  _ui_section_end 0 "Verificação do DB concluída"
}

# -----------------------
# integrity: permissions
# - ensure scripts are 0755 and build.conf 0644 (or fix with --fix)
# -----------------------
integrity_permissions() {
  _ui_section_start "Verificando permissões essenciais"
  # scripts
  shopt -s nullglob
  for s in "$ADM_SCRIPTS"/*.sh "$ADM_SCRIPTS"/*/*.sh; do
    [[ -f "$s" ]] || continue
    local mode
    mode="$(stat -c %a "$s" 2>/dev/null || echo "000")"
    if [[ "$mode" != "755" ]]; then
      _log_warn "Permissão inesperada em $s : $mode (esperado 755)"
      if [[ $MODE_FIX -eq 1 ]]; then
        if [[ $AUTO_YES -eq 1 ]] || confirm "Ajustar permissão para 0755 em $s?"; then
          chmod 0755 "$s" || _log_warn "Falha chmod $s"
          _log_info "Permissão ajustada: $s"
        fi
      fi
    fi
  done
  shopt -u nullglob

  # build.conf files
  while IFS= read -r -d '' bcf; do
    local bmode
    bmode="$(stat -c %a "$bcf" 2>/dev/null || echo "000")"
    if [[ "$bmode" != "644" ]]; then
      _log_warn "Permissão inesperada em $bcf : $bmode (esperado 644)"
      if [[ $MODE_FIX -eq 1 ]]; then
        if [[ $AUTO_YES -eq 1 ]] || confirm "Ajustar permissão para 0644 em $bcf?"; then
          chmod 0644 "$bcf" || _log_warn "Falha chmod $bcf"
          _log_info "Permissão ajustada: $bcf"
        fi
      fi
    fi
  done < <(find "$ADM_REPO" -type f -name 'build.conf' -print0 2>/dev/null)

  _ui_section_end 0 "Verificação de permissões"
}

# -----------------------
# summary
# -----------------------
integrity_summary() {
  _ui_section_start "Resumo de integridade"
  _log_info "Integrity completed: warnings=${_WARNINGS} errors=${_ERRORS}"
  if [[ "${_ERRORS}" -gt 0 ]]; then
    _ui_info "Erros detectados: ${_ERRORS}. Veja ${INTEGRITY_LOG}"
    _EXIT_CODE=2
  elif [[ "${_WARNINGS}" -gt 0 ]]; then
    _ui_info "Avisos: ${_WARNINGS}. Veja ${INTEGRITY_LOG}"
    _EXIT_CODE=1
  else
    _ui_info "Tudo OK. Log: ${INTEGRITY_LOG}"
    _EXIT_CODE=0
  fi
  _ui_section_end "$_EXIT_CODE" "Resumo de integridade"
}

# -----------------------
# CLI parsing
# -----------------------
_usage() {
  cat <<'EOF'
integrity.sh - integrity checks for ADM Build System

Usage:
  integrity.sh [--check] [--fix] [--scripts-only] [--sources-only] [--repo-only] [--yes] [--verbose]

Options:
  --check           Default: perform checks only
  --fix             Attempt safe fixes (permissions, create .sha256 when asked)
  --scripts-only    Only run scripts checks
  --sources-only    Only verify sources
  --repo-only       Only validate repo metadata
  --yes             Non-interactive: auto-confirm fixes
  --verbose         Verbose logging to stdout
  --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE_CHECK=1; shift ;;
    --fix) MODE_FIX=1; MODE_CHECK=0; shift ;;
    --scripts-only) SCOPE_SCRIPTS=1; SCOPE_SOURCES=0; SCOPE_REPO=0; SCOPE_ALL=0; shift ;;
    --sources-only) SCOPE_SOURCES=1; SCOPE_SCRIPTS=0; SCOPE_REPO=0; SCOPE_ALL=0; shift ;;
    --repo-only) SCOPE_REPO=1; SCOPE_SCRIPTS=0; SCOPE_SOURCES=0; SCOPE_ALL=0; shift ;;
    --yes|-y) AUTO_YES=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --help|-h) _usage; exit 0 ;;
    *)
      printf "Unknown arg: %s\n" "$1" >&2
      _usage
      exit 2
      ;;
  esac
done

# If --fix set, MODE_CHECK may be 0; ensure consistency
if [[ $MODE_FIX -eq 1 ]]; then
  MODE_CHECK=0
fi

# If any scoped mode set, set SCOPE_ALL=0
if [[ $SCOPE_SCRIPTS -eq 1 || $SCOPE_SOURCES -eq 1 || $SCOPE_REPO -eq 1 ]]; then
  SCOPE_ALL=0
fi

# -----------------------
# Main
# -----------------------
ensure_dirs

# Show header in UI if present
if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_header 2>/dev/null)" == "function" ]]; then
  ui_header
fi

# Run requested checks
if [[ $SCOPE_ALL -eq 1 || $SCOPE_SCRIPTS -eq 1 ]]; then
  integrity_scripts
fi

if [[ $SCOPE_ALL -eq 1 || $SCOPE_SOURCES -eq 1 ]]; then
  integrity_sources
fi

if [[ $SCOPE_ALL -eq 1 || $SCOPE_REPO -eq 1 ]]; then
  integrity_repo
fi

# DB and permissions always useful if full run
if [[ $SCOPE_ALL -eq 1 ]]; then
  integrity_db
  integrity_permissions
fi

integrity_summary

# exit with appropriate code
exit "${_EXIT_CODE:-0}"
