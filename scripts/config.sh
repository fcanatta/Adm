#!/usr/bin/env bash
# /usr/src/adm/scripts/config.sh
# ADM Build System - config manager (profiles, load/save/validate)
# Requirements: bash (assumes associative arrays supported), awk, sed, mkdir, date, gzip optional
set -o errexit
set -o nounset
set -o pipefail

# -----------------------
# Defaults & constants
# -----------------------
ADM_BASE="${ADM_BASE:-/usr/src/adm}"
ADM_CONFIG_DIR="${ADM_CONFIG:-$ADM_BASE/config}"
ADM_PROFILES_DIR="$ADM_CONFIG_DIR/profiles"
ADM_CONF_FILE="$ADM_CONFIG_DIR/adm.conf"
ADM_LOGS="${ADM_LOGS:-$ADM_BASE/logs}"
ADM_PKG_NAME="${ADM_PKG_NAME:-unknown}"
BUILD_ID="${BUILD_ID:-$(date +%Y-%m-%d_%H-%M-%S)}"

# Interaction with log.sh if present
_LOG_PRESENT=no
if [[ -r "${ADM_BASE}/scripts/log.sh" ]]; then
  # shellcheck disable=SC1090
  source "${ADM_BASE}/scripts/log.sh" || true
  _LOG_PRESENT=yes
fi

log_info_local() {
  if [[ "${_LOG_PRESENT}" == "yes" ]] && declare -F log_info >/dev/null; then
    log_info "$*"
  else
    : # silent fallback
  fi
}
log_warn_local() {
  if [[ "${_LOG_PRESENT}" == "yes" ]] && declare -F log_warn >/dev/null; then
    log_warn "$*"
  else
    printf "WARN: %s\n" "$*" >&2
  fi
}
log_error_local() {
  if [[ "${_LOG_PRESENT}" == "yes" ]] && declare -F log_error >/dev/null; then
    log_error "$*"
  else
    printf "ERROR: %s\n" "$*" >&2
  fi
}

# -----------------------
# Internal state
# -----------------------
# associative arrays to track variables and origin
declare -A CONFIG_VARS        # CONFIG_VARS[name]=value
declare -A CONFIG_ORIGIN      # CONFIG_ORIGIN[name]=filepath

# helper: ensure config directory exists
_config_ensure_dirs() {
  if [[ ! -d "$ADM_CONFIG_DIR" ]]; then
    if mkdir -p -m 0755 "$ADM_CONFIG_DIR" 2>/dev/null; then
      log_info_local "Created config dir: $ADM_CONFIG_DIR"
    else
      log_warn_local "Could not create config dir: $ADM_CONFIG_DIR (attempt fallback /tmp)"
      if mkdir -p -m 0755 "/tmp/adm-fallback/config" 2>/dev/null; then
        ADM_CONFIG_DIR="/tmp/adm-fallback/config"
        ADM_PROFILES_DIR="$ADM_CONFIG_DIR/profiles"
        ADM_CONF_FILE="$ADM_CONFIG_DIR/adm.conf"
        log_info_local "Using fallback config dir: $ADM_CONFIG_DIR"
      else
        log_error_local "Failed to ensure config dir"
        return 1
      fi
    fi
  fi
  mkdir -p -m 0755 "$ADM_PROFILES_DIR" 2>/dev/null || true
  return 0
}

# -----------------------
# Utilities
# -----------------------
_config_trim() {
  # trim whitespace
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

_config_nproc() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif [[ -r /proc/cpuinfo ]]; then
    grep -c ^processor /proc/cpuinfo || echo 1
  else
    echo 1
  fi
}

# -----------------------
# Parse a .conf file safely (no execution of arbitrary code)
# Only lines KEY=VALUE where KEY matches valid var name are accepted.
# Supports quoted values, and expands $(nproc) and simple $VAR references to known env.
# -----------------------
config_load() {
  local file="$1"
  if [[ -z "$file" ]]; then
    log_warn_local "config_load called without file"
    return 1
  fi
  if [[ ! -r "$file" ]]; then
    log_warn_local "Config file not found: $file"
    return 2
  fi

  # Read file line by line
  local line key val rest
  while IFS= read -r line || [[ -n "$line" ]]; do
    # remove leading/trailing whitespace
    line="$(_config_trim "$line")"
    # skip empty and comments
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    # accept only KEY=VALUE (KEY must start with letter or _)
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # strip surrounding quotes if any
      if [[ "${val:0:1}" == "'" && "${val: -1}" == "'" ]]; then
        val="${val:1:-1}"
      elif [[ "${val:0:1}" == '"' && "${val: -1}" == '"' ]]; then
        val="${val:1:-1}"
      fi
      # simple expansion: support $(nproc) and ${VAR} or $VAR for already-known env/config
      val="${val//\$(nproc)/$(_config_nproc)}"
      # expand environment variables safely by replacing $VAR or ${VAR} with current value if present
      val="$(printf '%s' "$val" | awk -v ENV_TBL="" '
        {
          gsub(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/, function(x,y){
            v = ENVIRON[y];
            if(v=="") v="";
            return v;
          });
          print;
        }')"
      # store
      CONFIG_VARS["$key"]="$val"
      CONFIG_ORIGIN["$key"]="$file"
      export "$key"="$val"
    else
      log_warn_local "Ignoring invalid config line in $file: $line"
    fi
  done <"$file"

  log_info_local "Loaded config: $file"
  return 0
}

# -----------------------
# Initialize configuration system and default adm.conf
# -----------------------
config_init() {
  _config_ensure_dirs || return 1

  # If adm.conf missing, create with reasonable defaults
  if [[ ! -f "$ADM_CONF_FILE" ]]; then
    cat >"$ADM_CONF_FILE" <<'EOF'
# adm.conf - ADM Build System global configuration (auto-generated if missing)
ADM_PROFILE="normal"        # default profile: basic, normal, conservador, agressivo
ADM_JOBS="$(nproc)"        # number of parallel jobs (overwritten by profiles)
ADM_MIRROR="https://mirror.example.org/sources"
ADM_LOGLEVEL="info"
EOF
    log_info_local "Created default adm.conf at $ADM_CONF_FILE"
  fi

  # Ensure profiles exist
  config_profiles_init

  # Load adm.conf now
  config_load "$ADM_CONF_FILE" || true

  # Ensure profile variable exists
  if [[ -z "${ADM_PROFILE:-}" ]]; then
    ADM_PROFILE="normal"
    export ADM_PROFILE
  fi

  # Apply profile
  config_profile_load "${ADM_PROFILE:-normal}"

  log_info_local "Configuration subsystem initialized"
  return 0
}

# -----------------------
# Reload hierarchy: adm.conf, package conf, local .adm.conf
# -----------------------
config_reload() {
  CONFIG_VARS=()
  CONFIG_ORIGIN=()
  # load global
  if [[ -f "$ADM_CONF_FILE" ]]; then
    config_load "$ADM_CONF_FILE"
  fi
  # package-specific: if ADM_PKG_NAME available
  if [[ -n "${ADM_PKG_NAME:-}" && -f "$ADM_CONFIG_DIR/${ADM_PKG_NAME}.conf" ]]; then
    config_load "$ADM_CONFIG_DIR/${ADM_PKG_NAME}.conf"
  fi
  # local .adm.conf in current dir
  if [[ -f "./.adm.conf" ]]; then
    config_load "./.adm.conf"
  fi
  # ensure profile loaded (adm.conf might have changed)
  if [[ -n "${ADM_PROFILE:-}" ]]; then
    config_profile_load "${ADM_PROFILE}"
  fi
  log_info_local "Configuration reloaded"
}

# -----------------------
# Get a config variable value
# -----------------------
config_get() {
  local key="$1"
  if [[ -z "$key" ]]; then
    printf "%s\n" ""
    return 1
  fi
  if [[ -n "${CONFIG_VARS[$key]:-}" ]]; then
    printf '%s\n' "${CONFIG_VARS[$key]}"
    return 0
  fi
  # fallback to environment
  if [[ -n "${!key:-}" ]]; then
    printf '%s\n' "${!key}"
    return 0
  fi
  return 2
}

# -----------------------
# Set a config variable (in-memory and persisted to adm.conf)
# Updates existing key or appends if not present.
# -----------------------
config_set() {
  local key="$1"
  local value="$2"
  if [[ -z "$key" ]]; then
    log_error_local "config_set requires a variable name"
    return 1
  fi
  CONFIG_VARS["$key"]="$value"
  CONFIG_ORIGIN["$key"]="$ADM_CONF_FILE"
  export "$key"="$value"

  # Persist into adm.conf: update key if exists, else append
  if [[ ! -f "$ADM_CONF_FILE" ]]; then
    mkdir -p "$(dirname "$ADM_CONF_FILE")" 2>/dev/null || true
    touch "$ADM_CONF_FILE"
  fi

  # Use awk to update or append while preserving other lines/comments
  awk -v K="$key" -v V="$value" -v OFS="" '
    BEGIN{ found=0 }
    {
      line=$0
      if (match(line, "^[[:space:]]*#")) { print line; next }
      if (match(line, "^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=")) {
        name=substr(line, RSTART, RLENGTH)
        sub(/[[:space:]]*=[[:space:]]*.*/,"",name)
        if (name==K) {
          print name"="V
          found=1
          next
        }
      }
      print line
    }
    END {
      if (found==0) print K"="V
    }
  ' "$ADM_CONF_FILE" > "${ADM_CONF_FILE}.tmp" && mv "${ADM_CONF_FILE}.tmp" "$ADM_CONF_FILE"

  log_info_local "Set config: $key=$value (persisted to $ADM_CONF_FILE)"
  return 0
}

# -----------------------
# List loaded variables and origin
# -----------------------
config_list() {
  # print in stable order
  for k in "${!CONFIG_VARS[@]}"; do
    printf "%-20s %s\t(%s)\n" "$k" "${CONFIG_VARS[$k]}" "${CONFIG_ORIGIN[$k]:-env}"
  done | sort
}

# -----------------------
# Validate minimal configuration integrity
# Ensures directories referenced exist, create them if possible.
# -----------------------
config_validate() {
  local ok=0
  # ensure essential dirs
  for d in "$ADM_BASE" "$ADM_CONFIG_DIR" "$ADM_LOGS" "$ADM_BASE/repo" "$ADM_BASE/db" ; do
    if [[ ! -d "$d" ]]; then
      if mkdir -p -m 0755 "$d" 2>/dev/null; then
        log_info_local "config_validate: Created missing dir $d"
      else
        log_warn_local "config_validate: Could not create $d"
        ok=1
      fi
    fi
  done

  # ensure profiles
  config_profile_validate || ok=1

  if [[ "$ok" -ne 0 ]]; then
    log_warn_local "config_validate: Issues found (see warnings)"
    return 1
  fi
  log_info_local "config_validate: OK"
  return 0
}

# -----------------------
# Persist current in-memory variables into adm.conf (non-destructive)
# Writes keys in CONFIG_VARS (origin adm.conf)
# -----------------------
config_save() {
  # ensure adm.conf exists
  if [[ ! -f "$ADM_CONF_FILE" ]]; then
    touch "$ADM_CONF_FILE"
  fi

  # read original file into array
  local tmp="${ADM_CONF_FILE}.tmp.$$"
  cp "$ADM_CONF_FILE" "$tmp" 2>/dev/null || : 
  # For each key in CONFIG_VARS that should be persisted, update or append
  for key in "${!CONFIG_VARS[@]}"; do
    # update file: replace line starting with key=
    if grep -q -E "^[[:space:]]*${key}[[:space:]]*=" "$ADM_CONF_FILE" 2>/dev/null; then
      sed -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key}=${CONFIG_VARS[$key]}|" "$ADM_CONF_FILE" > "${ADM_CONF_FILE}.tmp2.$$" && mv "${ADM_CONF_FILE}.tmp2.$$" "$ADM_CONF_FILE"
    else
      printf "%s=%s\n" "$key" "${CONFIG_VARS[$key]}" >> "$ADM_CONF_FILE"
    fi
  done

  rm -f "$tmp" 2>/dev/null || true
  log_info_local "config_save: Persisted in-memory config to $ADM_CONF_FILE"
}

# -----------------------
# Edit adm.conf with $EDITOR
# -----------------------
config_edit() {
  local editor="${EDITOR:-${VISUAL:-nano}}"
  if [[ ! -f "$ADM_CONF_FILE" ]]; then
    touch "$ADM_CONF_FILE"
  fi
  "$editor" "$ADM_CONF_FILE"
  config_reload
  log_info_local "config_edit: Edited $ADM_CONF_FILE with $editor"
}

# -----------------------
# Profiles management
# -----------------------
_config_write_profile_defaults() {
  local prof="$1"
  local path="$ADM_PROFILES_DIR/${prof}.conf"
  case "$prof" in
    agressivo)
      cat >"$path" <<'EOF'
# agressivo profile - maximum optimizations
CFLAGS="-O3 -pipe -march=native -flto"
CXXFLAGS="-O3 -pipe -march=native -flto"
MAKEFLAGS="-j$(nproc)"
LDFLAGS="-Wl,-O1,--as-needed -flto"
EOF
      ;;
    normal)
      cat >"$path" <<'EOF'
# normal profile - balanced
CFLAGS="-O2 -pipe"
CXXFLAGS="-O2 -pipe"
MAKEFLAGS="-j$(nproc)"
LDFLAGS="-Wl,-O1,--as-needed"
EOF
      ;;
    conservador)
      cat >"$path" <<'EOF'
# conservador profile - safe
CFLAGS="-O1 -pipe -fno-strict-aliasing"
CXXFLAGS="-O1 -pipe -fno-strict-aliasing"
MAKEFLAGS="-j2"
LDFLAGS="-Wl,-O1"
EOF
      ;;
    basico)
      cat >"$path" <<'EOF'
# basico profile - minimal for bootstrap
CFLAGS="-O0"
CXXFLAGS="-O0"
MAKEFLAGS="-j1"
LDFLAGS=""
EOF
      ;;
    *)
      return 1
      ;;
  esac
  chmod 0644 "$path" 2>/dev/null || true
}

config_profiles_init() {
  mkdir -p "$ADM_PROFILES_DIR" 2>/dev/null || return 1
  # default profiles
  for p in agressivo normal conservador basico; do
    if [[ ! -f "$ADM_PROFILES_DIR/${p}.conf" ]]; then
      _config_write_profile_defaults "$p"
      log_info_local "Created profile: $p"
    fi
  done
  return 0
}

config_profile_list() {
  local active="${ADM_PROFILE:-}"
  echo "Perfis disponiveis:"
  for f in "$ADM_PROFILES_DIR"/*.conf; do
    [[ -e "$f" ]] || continue
    local name
    name="$(basename "$f" .conf)"
    if [[ "$name" == "$active" ]]; then
      printf " * %s\t(active)\n" "$name"
    else
      printf "   %s\n" "$name"
    fi
  done
}

config_profile_load() {
  local prof="${1:-${ADM_PROFILE:-normal}}"
  if [[ ! -f "$ADM_PROFILES_DIR/${prof}.conf" ]]; then
    log_warn_local "Profile not found: $prof"
    return 2
  fi
  # load profile config (re-use config_load logic)
  config_load "$ADM_PROFILES_DIR/${prof}.conf"
  # ensure MAKEFLAGS expanded with nproc if contains $(nproc)
  if [[ -n "${MAKEFLAGS:-}" ]]; then
    MAKEFLAGS="${MAKEFLAGS//\$(nproc)/$(_config_nproc)}"
    export MAKEFLAGS
  fi
  ADM_PROFILE="$prof"
  export ADM_PROFILE
  log_info_local "Loaded profile: $prof"
}

config_profile_set() {
  local prof="$1"
  if [[ -z "$prof" ]]; then
    log_error_local "config_profile_set requires a profile name"
    return 1
  fi
  if [[ ! -f "$ADM_PROFILES_DIR/${prof}.conf" ]]; then
    log_warn_local "Profile $prof does not exist, creating default"
    _config_write_profile_defaults "$prof" || {
      log_error_local "Failed to create profile $prof"
      return 1
    }
  fi
  config_profile_load "$prof"
  # persist profile choice in adm.conf
  config_set "ADM_PROFILE" "$prof"
  log_info_local "Profile set to: $prof"
}

config_profile_validate() {
  # ensure profiles dir exists and default profiles are present
  if [[ ! -d "$ADM_PROFILES_DIR" ]]; then
    mkdir -p "$ADM_PROFILES_DIR" 2>/dev/null || return 1
  fi
  local ok=0
  for p in agressivo normal conservador basico; do
    if [[ ! -f "$ADM_PROFILES_DIR/${p}.conf" ]]; then
      _config_write_profile_defaults "$p" || ok=1
      log_warn_local "Missing profile $p recreated"
    fi
  done
  # ensure ADM_PROFILE is set and valid
  if [[ -z "${ADM_PROFILE:-}" || ! -f "$ADM_PROFILES_DIR/${ADM_PROFILE}.conf" ]]; then
    ADM_PROFILE="normal"
    export ADM_PROFILE
    config_profile_load "$ADM_PROFILE" || true
    log_info_local "ADM_PROFILE not valid, defaulted to normal"
  fi
  return $ok
}

# -----------------------
# Help / usage
# -----------------------
config_help() {
  cat <<'EOF'
config.sh - ADM Build configuration manager

Available functions (source this file and call):
  config_init             - initialize config system and profiles
  config_load <file>      - load a single config file
  config_reload           - reload adm.conf, package and local .adm.conf
  config_get <VAR>        - print value of variable
  config_set <VAR> <VAL>  - set variable and persist to adm.conf
  config_list             - list loaded variables and origin
  config_save             - persist in-memory config to adm.conf
  config_edit             - open adm.conf in $EDITOR (or nano)
  config_validate         - validate configuration integrity
  config_profiles_init    - ensure profiles exist
  config_profile_list     - list profiles (active marked)
  config_profile_load <p> - load profile p (exports flags)
  config_profile_set <p>  - set profile p and persist
  config_profile_validate - validate profiles availability

EOF
}

# If executed directly, show help
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  config_help
  exit 0
fi

# Export functions for other scripts (when sourced)
export -f config_init config_load config_reload config_get config_set config_list config_save config_edit config_validate
export -f config_profiles_init config_profile_load config_profile_set config_profile_list config_profile_validate
