#!/usr/bin/env bash
# /usr/src/adm/scripts/profile.sh
# Profile manager for ADM Build System
# - creates default profiles on first run (with secure perms)
# - supports inheritance via "extends="
# - auto-detects hardware and suggests flags
# - validates and exports profile variables to environment
# - interactive editor for custom profile
set -euo pipefail

# try to source lib for logging and header; fallbacks provided
if [ -n "${ADM_SCRIPTS_DIR-}" ] && [ -f "${ADM_SCRIPTS_DIR}/lib.sh" ]; then
  # shellcheck disable=SC1090
  source "${ADM_SCRIPTS_DIR}/lib.sh"
else
  info()  { printf "[INFO]  %s\n" "$*"; }
  ok()    { printf "[ OK ]  %s\n" "$*"; }
  warn()  { printf "[WARN]  %s\n" "$*"; }
  err()   { printf "[ERR]  %s\n" "$*"; }
  fatal() { printf "[FATAL] %s\n" "$*"; exit 1; }
  show_header() { :; }
fi

# defaults and paths
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
PROFILES_DIR="${ADM_STATE:-${ADM_ROOT}/state}/profiles"
CURRENT_PROFILE="${ADM_STATE:-${ADM_ROOT}/state}/current.profile"
BACKUP_DIR="${ADM_STATE:-${ADM_ROOT}/state}/backups"
DEFAULT_ACTIVE_PROFILE="${ADM_PROFILE:-performance}"

# permission constants
DIR_MODE=755
FILE_MODE=644

# ensure directories
ensure_dirs() {
  mkdir -p "${PROFILES_DIR}"
  mkdir -p "${BACKUP_DIR}"
  chmod "${DIR_MODE}" "${PROFILES_DIR}" 2>/dev/null || true
  chown root:root "${PROFILES_DIR}" 2>/dev/null || true
}

# write default profile file helper
_write_profile_file() {
  local path="$1"; shift
  cat > "${path}" <<'EOF'
__CONTENT__
EOF
}

# Create the default set of profiles if they don't exist
create_default_profiles() {
  ensure_dirs

  # minimal
  if [ ! -f "${PROFILES_DIR}/minimal.profile" ]; then
    cat > "${PROFILES_DIR}/minimal.profile" <<'EOF'
CFLAGS=-O1 -pipe
CXXFLAGS=-O1 -pipe
LDFLAGS=-Wl,-O1
MAKEFLAGS=-j1
ADM_USE_CACHE=0
ADM_STRIP_BINARIES=1
ADM_DEBUG_SYMBOLS=0
ADM_LTO=0
ADM_PROFILE_DESC=Compilação genérica e estável com baixo consumo de recursos.
EOF
    chmod "${FILE_MODE}" "${PROFILES_DIR}/minimal.profile" 2>/dev/null || true
    chown root:root "${PROFILES_DIR}/minimal.profile" 2>/dev/null || true
    ok "Created profile: minimal"
  fi

  # performance
  if [ ! -f "${PROFILES_DIR}/performance.profile" ]; then
    cat > "${PROFILES_DIR}/performance.profile" <<'EOF'
extends=minimal
CFLAGS=-O2 -march=native -pipe
CXXFLAGS=-O2 -march=native -pipe
LDFLAGS=-Wl,-O1 -Wl,--as-needed
MAKEFLAGS=-j$(nproc)
ADM_USE_CACHE=1
ADM_STRIP_BINARIES=1
ADM_DEBUG_SYMBOLS=0
ADM_LTO=0
ADM_PROFILE_DESC=Equilíbrio entre desempenho e estabilidade.
EOF
    chmod "${FILE_MODE}" "${PROFILES_DIR}/performance.profile" 2>/dev/null || true
    chown root:root "${PROFILES_DIR}/performance.profile" 2>/dev/null || true
    ok "Created profile: performance"
  fi

  # balanced
  if [ ! -f "${PROFILES_DIR}/balanced.profile" ]; then
    cat > "${PROFILES_DIR}/balanced.profile" <<'EOF'
extends=performance
CFLAGS=-O2 -march=native -pipe -fstack-protector-strong
LDFLAGS=-Wl,-O2 -Wl,--as-needed
ADM_LTO=1
ADM_DEBUG_SYMBOLS=0
ADM_PROFILE_DESC=Perfil equilibrado para sistemas desktop e laptops.
EOF
    chmod "${FILE_MODE}" "${PROFILES_DIR}/balanced.profile" 2>/dev/null || true
    chown root:root "${PROFILES_DIR}/balanced.profile" 2>/dev/null || true
    ok "Created profile: balanced"
  fi

  # aggressive
  if [ ! -f "${PROFILES_DIR}/aggressive.profile" ]; then
    cat > "${PROFILES_DIR}/aggressive.profile" <<'EOF'
extends=performance
CFLAGS=-O3 -march=native -pipe -flto
CXXFLAGS=-O3 -march=native -pipe -flto
LDFLAGS=-Wl,-O3 -Wl,--as-needed -flto
ADM_STRIP_BINARIES=0
ADM_DEBUG_SYMBOLS=0
ADM_LTO=1
ADM_PROFILE_DESC=Build agressivo com LTO e otimizações máximas.
EOF
    chmod "${FILE_MODE}" "${PROFILES_DIR}/aggressive.profile" 2>/dev/null || true
    chown root:root "${PROFILES_DIR}/aggressive.profile" 2>/dev/null || true
    ok "Created profile: aggressive"
  fi

  # debug
  if [ ! -f "${PROFILES_DIR}/debug.profile" ]; then
    cat > "${PROFILES_DIR}/debug.profile" <<'EOF'
extends=minimal
CFLAGS=-O0 -g -pipe
CXXFLAGS=-O0 -g -pipe
LDFLAGS=-Wl,-O0
ADM_USE_CACHE=0
ADM_STRIP_BINARIES=0
ADM_DEBUG_SYMBOLS=1
ADM_LTO=0
ADM_PROFILE_DESC=Perfil para depuração e desenvolvimento.
EOF
    chmod "${FILE_MODE}" "${PROFILES_DIR}/debug.profile" 2>/dev/null || true
    chown root:root "${PROFILES_DIR}/debug.profile" 2>/dev/null || true
    ok "Created profile: debug"
  fi

  # server
  if [ ! -f "${PROFILES_DIR}/server.profile" ]; then
    local half_j
    half_j="$(nproc 2>/dev/null || echo 1)"
    # fallback compute half
    half_j=$(( (half_j + 1) / 2 ))
    cat > "${PROFILES_DIR}/server.profile" <<EOF
extends=minimal
CFLAGS=-O2 -pipe -mtune=generic
LDFLAGS=-Wl,-O1 -Wl,--as-needed
MAKEFLAGS=-j${half_j}
ADM_USE_CACHE=1
ADM_STRIP_BINARIES=1
ADM_DEBUG_SYMBOLS=0
ADM_LTO=0
ADM_PROFILE_DESC=Compilação otimizada para servidores estáveis.
EOF
    chmod "${FILE_MODE}" "${PROFILES_DIR}/server.profile" 2>/dev/null || true
    chown root:root "${PROFILES_DIR}/server.profile" 2>/dev/null || true
    ok "Created profile: server"
  fi

  # ensure a current.profile exists
  if [ ! -f "${CURRENT_PROFILE}" ]; then
    mkdir -p "$(dirname "${CURRENT_PROFILE}")"
    cp -f "${PROFILES_DIR}/${DEFAULT_ACTIVE_PROFILE}.profile" "${CURRENT_PROFILE}" 2>/dev/null || true
    chmod "${FILE_MODE}" "${CURRENT_PROFILE}" 2>/dev/null || true
    ok "Initialized current.profile -> ${DEFAULT_ACTIVE_PROFILE}"
  fi
}

# parse a profile file into an associative array, handling 'key=value' and ignoring comments
# usage: parse_profile_into_assoc <profilefile> <assocname>
parse_profile_into_assoc() {
  local file="$1"; local assoc_name="$2"
  declare -gA "${assoc_name}=()"
  local -n __assoc_ref="${assoc_name}"

  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    # strip CR and trim
    line="${line%%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    # skip comments and empty
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if ! echo "$line" | grep -q "="; then
      continue
    fi
    key="${line%%=*}"; val="${line#*=}"
    key="$(echo "$key" | tr -d '[:space:]')"
    val="$(echo "$val" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    __assoc_ref["$key"]="$val"
  done < "$file"
  return 0
}

# load profile by name (resolves extends recursively), result in assoc array 'PROFILE_VARS'
load_profile_by_name() {
  local name="$1"
  local file="${PROFILES_DIR}/${name}.profile"
  if [ ! -f "$file" ]; then
    fatal "Profile not found: ${name} (${file})"
  fi
  declare -gA PROFILE_VARS=()
  # recursive loader
  _load_profile_recursive() {
    local f="$1"
    local tmp_assoc
    tmp_assoc="_tmp_$$"
    parse_profile_into_assoc "$f" "$tmp_assoc" || return 1
    local -n tmp_ref="${tmp_assoc}"
    # handle extends first
    if [ -n "${tmp_ref[extends]-}" ]; then
      local base="${tmp_ref[extends]}"
      # resolve relative simple name to file if needed
      if [ -f "${PROFILES_DIR}/${base}.profile" ]; then
        _load_profile_recursive "${PROFILES_DIR}/${base}.profile"
      else
        warn "Base profile not found: ${base}"
      fi
    fi
    # merge keys (child overrides)
    for k in "${!tmp_ref[@]}"; do
      PROFILE_VARS["$k"]="${tmp_ref[$k]}"
    done
    unset "$tmp_assoc"
  }
  _load_profile_recursive "$file"
}

# expand profile values: allow simple $(nproc) substitution and command substitution safely
_expand_value() {
  local v="$1"
  # replace $(nproc) first (fast)
  if echo "$v" | grep -q '\$\(nproc\)'; then
    n=$(nproc 2>/dev/null || echo 1)
    v="${v//\$\([nN][pP][rR][oO][cC]\)/$n}"
  fi
  # allow arithmetic like $((...)) or other harmless expansions: evaluate in subshell
  # NOTE: this executes what's inside; profiles are local/trusted.
  if echo "$v" | grep -q '\$[(]'; then
    # use eval in a subshell to avoid affecting current env
    v="$(bash -c "echo $v" 2>/dev/null || echo "$v")"
  fi
  printf "%s" "$v"
}

# export PROFILE_VARS to environment with expansion and validation
export_profile_env() {
  if [ -z "${PROFILE_VARS+x}" ]; then
    fatal "No profile loaded. Use load_profile_by_name or reload first."
  fi
  # export a whitelist of known vars; other keys will be exported too (prefixed)
  local allowed=(CFLAGS CXXFLAGS LDFLAGS MAKEFLAGS ADM_USE_CACHE ADM_STRIP_BINARIES ADM_DEBUG_SYMBOLS ADM_LTO ADM_PROFILE_DESC)
  for k in "${!PROFILE_VARS[@]}"; do
    local v="${PROFILE_VARS[$k]}"
    v="$(_expand_value "$v")"
    # safety: remove surrounding quotes if any
    v="${v#\"}"; v="${v%\"}"
    export "$k"="$v"
  done
  # ensure MAKEFLAGS uses -jN; if not set, set a default
  if [ -z "${MAKEFLAGS-}" ] || [ "${MAKEFLAGS}" = "" ]; then
    export MAKEFLAGS="-j$(nproc 2>/dev/null || echo 1)"
  fi
  # persist current.profile copy
  mkdir -p "$(dirname "${CURRENT_PROFILE}")"
  {
    for k in "${!PROFILE_VARS[@]}"; do
      printf "%s=%s\n" "$k" "${PROFILE_VARS[$k]}"
    done
  } > "${CURRENT_PROFILE}.tmp"
  mv -f "${CURRENT_PROFILE}.tmp" "${CURRENT_PROFILE}" 2>/dev/null || true
  chmod "${FILE_MODE}" "${CURRENT_PROFILE}" 2>/dev/null || true
  ok "Profile exported and saved to ${CURRENT_PROFILE}"
}

# validate basic required variables
validate_loaded_profile() {
  # require CFLAGS and MAKEFLAGS at minimum
  local errs=0
  if [ -z "${PROFILE_VARS[CFLAGS]-}" ]; then
    warn "CFLAGS not set in profile; defaulting to -O2 -pipe"
    PROFILE_VARS[CFLAGS]="-O2 -pipe"
    errs=$((errs+1))
  fi
  if [ -z "${PROFILE_VARS[MAKEFLAGS]-}" ]; then
    warn "MAKEFLAGS not set; defaulting to -j$(nproc 2>/dev/null || echo 1)"
    PROFILE_VARS[MAKEFLAGS]="-j$(nproc 2>/dev/null || echo 1)"
    errs=$((errs+1))
  fi
  # verify MAKEFLAGS contains -j
  if ! echo "${PROFILE_VARS[MAKEFLAGS]}" | grep -qE '\-j[0-9]+'; then
    warn "MAKEFLAGS does not contain -jN; adding -j$(nproc 2>/dev/null || echo 1)"
    PROFILE_VARS[MAKEFLAGS]="-j$(nproc 2>/dev/null || echo 1) ${PROFILE_VARS[MAKEFLAGS]:-}"
    errs=$((errs+1))
  fi
  if [ "$errs" -gt 0 ]; then
    warn "Profile had $errs issues fixed automatically"
  fi
  return 0
}

# list available profiles
list_profiles() {
  ensure_dirs
  echo "Available profiles:"
  local active_name=""
  if [ -f "${CURRENT_PROFILE}" ]; then
    # try to detect name by matching files
    for f in "${PROFILES_DIR}"/*.profile; do
      [ -f "$f" ] || continue
      if cmp -s "$f" "${CURRENT_PROFILE}" 2>/dev/null; then
        active_name="$(basename "$f" .profile)"
        break
      fi
    done
  fi
  for p in "${PROFILES_DIR}"/*.profile; do
    [ -f "$p" ] || continue
    local name; name="$(basename "$p" .profile)"
    if [ "$name" = "$active_name" ]; then
      printf " - %s (active)\n" "$name"
    else
      printf " - %s\n" "$name"
    fi
  done
}

# show current profile details (loaded)
show_profile() {
  if [ -z "${PROFILE_VARS+x}" ]; then
    if [ -f "${CURRENT_PROFILE}" ]; then
      load_profile_by_name "$(basename "${CURRENT_PROFILE}" .profile 2>/dev/null || echo "${DEFAULT_ACTIVE_PROFILE}")" || true
    else
      fatal "No profile loaded and no current.profile present"
    fi
  fi
  echo "Profile variables:"
  for k in "${!PROFILE_VARS[@]}"; do
    printf "%-20s = %s\n" "$k" "${PROFILE_VARS[$k]}"
  done | sort
}

# set profile by name (loads, validates, exports)
set_profile() {
  local name="$1"
  if [ -z "$name" ]; then
    fatal "set_profile <name>"
  fi
  local file="${PROFILES_DIR}/${name}.profile"
  if [ ! -f "$file" ]; then
    fatal "Profile does not exist: $name"
  fi
  # backup current.profile
  if [ -f "${CURRENT_PROFILE}" ]; then
    mkdir -p "${BACKUP_DIR}"
    cp -f "${CURRENT_PROFILE}" "${BACKUP_DIR}/current.profile.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
  fi
  load_profile_by_name "$name"
  validate_loaded_profile
  export_profile_env
  ok "Profile set to ${name}"
}

# reload current.profile file (useful after editing)
reload_profile() {
  if [ -f "${CURRENT_PROFILE}" ]; then
    # try to infer name by matching existing profile files (not mandatory)
    # load it directly: create temp assoc
    declare -gA PROFILE_VARS=()
    parse_profile_into_assoc "${CURRENT_PROFILE}" _tmp_profile || true
    # move to PROFILE_VARS
    local -n tmp_ref=_tmp_profile
    for k in "${!tmp_ref[@]}"; do
      PROFILE_VARS["$k"]="${tmp_ref[$k]}"
    done
    unset _tmp_profile
    validate_loaded_profile
    export_profile_env
    ok "Reloaded profile from ${CURRENT_PROFILE}"
  else
    fatal "No current.profile to reload"
  fi
}

# interactive editor for creating/modifying a profile (simple)
interactive_profile_editor() {
  ensure_dirs
  echo "Interactive profile editor"
  read -rp "Profile name (new or existing): " pname
  [ -n "$pname" ] || { warn "Empty name; abort"; return 1; }
  pfile="${PROFILES_DIR}/${pname}.profile"
  if [ -f "$pfile" ]; then
    ok "Editing existing: $pfile"
  else
    ok "Creating new profile: $pfile"
    touch "$pfile"
    chmod "${FILE_MODE}" "$pfile" 2>/dev/null || true
  fi
  # load into assoc
  declare -A edit_vars=()
  parse_profile_into_assoc "$pfile" _tmp_edit || true
  local -n edit_ref=_tmp_edit
  # menu loop
  while :; do
    clear
    echo "Editing profile: $pname"
    echo "Current variables:"
    for k in "${!edit_ref[@]}"; do printf "  %s=%s\n" "$k" "${edit_ref[$k]}"; done | sort
    cat <<'EOF'

Options:
  1) set KEY=VALUE
  2) unset KEY
  3) save & exit
  4) discard & exit
  5) detect hardware and suggest MAKEFLAGS/CFLAGS
EOF
    read -rp "Choice: " ch
    case "$ch" in
      1)
        read -rp "Enter KEY=VALUE: " kv
        if echo "$kv" | grep -q '='; then
          kk="${kv%%=*}"
          vv="${kv#*=}"
          edit_ref["$kk"]="$vv"
        else
          warn "Invalid format"
        fi
        ;;
      2)
        read -rp "Enter KEY to remove: " rk
        unset edit_ref["$rk"]
        ;;
      3)
        # write file
        {
          for k in "${!edit_ref[@]}"; do
            printf "%s=%s\n" "$k" "${edit_ref[$k]}"
          done
        } > "${pfile}.tmp"
        mv -f "${pfile}.tmp" "${pfile}"
        chmod "${FILE_MODE}" "${pfile}" 2>/dev/null || true
        ok "Saved ${pfile}"
        break
        ;;
      4)
        warn "Discarded changes"
        break
        ;;
      5)
        # run detect and inject suggestions
        detect_arch_auto
        echo "Suggested MAKEFLAGS=${SUGGESTED_MAKEFLAGS}"
        echo "Suggested CFLAGS=${SUGGESTED_CFLAGS}"
        read -rp "Apply suggestions? [y/N]: " a
        case "$a" in
          y|Y)
            edit_ref[MAKEFLAGS]="${SUGGESTED_MAKEFLAGS}"
            edit_ref[CFLAGS]="${SUGGESTED_CFLAGS}"
            ok "Suggestions applied"
            ;;
          *) info "Not applied" ;;
        esac
        ;;
      *) warn "Unknown choice" ;;
    esac
  done
  unset _tmp_edit
}

# detect hardware and prepare suggestion variables
detect_arch_auto() {
  local arch cores mem_gb cpu_name
  arch="$(uname -m 2>/dev/null || echo unknown)"
  cores="$(nproc 2>/dev/null || echo 1)"
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  mem_gb=$(( (mem_kb + 1024*1024 -1) / (1024*1024) )) # MB->GB approx
  cpu_name="$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)"
  cpu_name="$(echo "$cpu_name" | sed -E 's/^[[:space:]]+//')"
  # suggestions
  SUGGESTED_MAKEFLAGS="-j${cores}"
  SUGGESTED_CFLAGS="-O2 -march=native -pipe"
  # tune down for low RAM
  if [ "$mem_gb" -lt 4 ]; then
    # reduce jobs half
    local half=$(( (cores+1)/2 ))
    SUGGESTED_MAKEFLAGS="-j${half}"
    SUGGESTED_CFLAGS="-O2 -pipe"
  fi
  # output for caller
  ok "Detected arch=${arch} cpu='${cpu_name}' cores=${cores} mem=${mem_gb}MB"
}

# CLI dispatcher
_show_help() {
  cat <<EOF
Usage: profile.sh <command>

Commands:
  list                List available profiles
  show                Show currently loaded profile variables
  set <name>          Set profile (loads, validates and exports)
  reload              Reload current.profile and export
  export              Print exported variables (for debugging)
  detect              Run hardware detection and show suggested flags
  --interactive       Interactive editor to create/modify profiles
  --validate          Validate current profile (check/fix common issues)
  help                Show this help
EOF
}

main() {
  ensure_dirs
  create_default_profiles

  case "${1-}" in
    list) list_profiles; return 0 ;;
    show) 
      # try to load from current.profile if not loaded
      if [ -f "${CURRENT_PROFILE}" ]; then
        parse_profile_into_assoc "${CURRENT_PROFILE}" _tmp_load || true
        declare -gA PROFILE_VARS=()
        local -n tmp_ref=_tmp_load
        for k in "${!tmp_ref[@]}"; do PROFILE_VARS["$k"]="${tmp_ref[$k]}"; done
        unset _tmp_load
      fi
      show_profile; return 0 ;;
    set)
      if [ -z "${2-}" ]; then fatal "set requires profile name"; fi
      set_profile "$2"; return 0 ;;
    reload)
      reload_profile; return 0 ;;
    export)
      if [ -z "${PROFILE_VARS+x}" ]; then fatal "No profile loaded"; fi
      for k in "${!PROFILE_VARS[@]}"; do printf "export %s='%s'\n" "$k" "$(_expand_value "${PROFILE_VARS[$k]}")"; done
      return 0 ;;
    detect)
      detect_arch_auto; return 0 ;;
    --interactive)
      interactive_profile_editor; return 0 ;;
    --validate)
      if [ -z "${PROFILE_VARS+x}" ]; then
        if [ -f "${CURRENT_PROFILE}" ]; then
          parse_profile_into_assoc "${CURRENT_PROFILE}" _tmp_val || true
          declare -gA PROFILE_VARS=()
          local -n tmp_ref=_tmp_val
          for k in "${!tmp_ref[@]}"; do PROFILE_VARS["$k"]="${tmp_ref[$k]}"; done
          unset _tmp_val
        else
          fatal "No current profile to validate"
        fi
      fi
      validate_loaded_profile; export_profile_env; return 0 ;;
    help|--help|-h) _show_help; return 0 ;;
    "")
      # default: show current profile summary
      if [ -f "${CURRENT_PROFILE}" ]; then
        parse_profile_into_assoc "${CURRENT_PROFILE}" _tmp_def || true
        declare -gA PROFILE_VARS=()
        local -n tmp_ref=_tmp_def
        for k in "${!tmp_ref[@]}"; do PROFILE_VARS["$k"]="${tmp_ref[$k]}"; done
        unset _tmp_def
        validate_loaded_profile
        export_profile_env
        show_profile
        return 0
      else
        fatal "No current.profile present; run 'profile.sh list' to see available profiles"
      fi
      ;;
    *)
      fatal "Unknown command: ${1-}. See 'profile.sh help'"
      ;;
  esac
}

# run main with all args
main "$@"
