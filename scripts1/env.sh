#!/usr/bin/env bash
# env.sh - Inicializador de ambiente ADM
# Local sugerido: /usr/src/adm/scripts/env.sh
# Faça executável: chmod +x /usr/src/adm/scripts/env.sh
#
# Funções:
#  - define/expõe variáveis globais usadas por todo o projeto
#  - cria a árvore mínima: scripts, var, etc, meta, src, update, usr/target
#  - gera arquivos de configuração defaults se ausentes
#  - detecta modo (HOST vs CHROOT/TARGET) de forma não invasiva
#
set -euo pipefail
IFS=$'\n\t'

# ---------- CONFIG ----------
: "${ADM_ROOT:=/usr/src/adm}"

ADM_SCRIPTS="$ADM_ROOT/scripts"
ADM_ETC="$ADM_ROOT/etc"
ADM_VAR="$ADM_ROOT/var"
ADM_LOG="$ADM_VAR/log/adm.log"
ADM_DB="$ADM_VAR/db"
ADM_TMP="$ADM_VAR/tmp"
ADM_META="$ADM_ROOT/meta"
ADM_SRC="$ADM_ROOT/src"
ADM_UPDATE="$ADM_ROOT/update"
ADM_TARGET="$ADM_ROOT/usr/target"
ADM_PROFILES_DIR="$ADM_ETC/profiles"

# default profile (can be overwritten by adm.conf)
ADM_PROFILE_FILE="$ADM_ETC/adm.conf"
ADM_DEFAULT_PROFILE="normal"

# minimal umask
: "${ADM_UMASK:=0022}"

# ---------- UTIL HELPERS ----------
_mkdir_p() {
  # safe mkdir -p with umask respected
  umask "$ADM_UMASK"
  mkdir -p "$@"
  umask 022
}

_write_default_conf() {
  local dest="$1"
  local content="$2"
  if [ ! -f "$dest" ]; then
    printf "%s\n" "$content" > "$dest"
    chmod 0644 "$dest"
  fi
}

# ---------- ACTIONS ----------
ensure_tree() {
  # create minimal directories and files
  _mkdir_p "$ADM_SCRIPTS"
  _mkdir_p "$ADM_ETC"
  _mkdir_p "$ADM_VAR"
  _mkdir_p "$ADM_LOG" 2>/dev/null || true
  _mkdir_p "$ADM_DB"
  _mkdir_p "$ADM_TMP"
  _mkdir_p "$ADM_META"
  _mkdir_p "$ADM_SRC"
  _mkdir_p "$ADM_UPDATE"
  _mkdir_p "$ADM_TARGET"
  _mkdir_p "$ADM_PROFILES_DIR"
  # ensure log file exists
  touch "$ADM_LOG" 2>/dev/null || true
  # ensure db dir exists
  touch "$ADM_DB/.placeholder" 2>/dev/null || true
}

detect_mode() {
  # Set ADM_MODE variable: HOST or TARGET
  # Heuristic: if /proc/1/comm is 'systemd' and ADM_TARGET is a different mountpoint? keep simple:
  ADM_MODE="HOST"
  # if running inside a chroot where / is not same device as /proc/1 root? keep safe non-invasive:
  if [ -f "/.dockerenv" ] || grep -qE '/usr/src/adm' /proc/1/cmdline 2>/dev/null; then
    ADM_MODE="TARGET"
  fi
  export ADM_MODE
}

load_profile_defaults() {
  # create default profiles if missing
  _write_default_conf "$ADM_PROFILES_DIR/simple.conf" "CFLAGS=\"-O1 -pipe\"\nLDFLAGS=\"\"\nMAKEJOBS=1"
  _write_default_conf "$ADM_PROFILES_DIR/normal.conf" "CFLAGS=\"-O2 -pipe\"\nLDFLAGS=\"\"\nMAKEJOBS=\$(nproc 2>/dev/null || echo 1)"
  _write_default_conf "$ADM_PROFILES_DIR/otimizado.conf" "CFLAGS=\"-O3 -flto -march=native -pipe\"\nLDFLAGS=\"-flto\"\nMAKEJOBS=\$(nproc 2>/dev/null || echo 1)"
}

create_adm_conf() {
  if [ ! -f "$ADM_PROFILE_FILE" ]; then
    cat > "$ADM_PROFILE_FILE" <<'EOF'
# adm.conf - configurações principais do ADM (gerado automaticamente)
# DEFAULT_PROFILE pode ser: simple, normal, otimizado
DEFAULT_PROFILE=normal
MIRRORS="https://example-mirror.org"
DOWNLOAD_RETRY=3
MAKEJOBS=
EOF
    chmod 0644 "$ADM_PROFILE_FILE"
  fi
}

load_adm_conf() {
  # safe load: only KEY=VALUE simple vars; ignore others
  if [ -f "$ADM_PROFILE_FILE" ]; then
    # shell-safe source within a subshell to parse simple KEY=VALUE lines:
    # we'll read line-by-line and export known keys
    while IFS='=' read -r key val; do
      key=$(echo "$key" | tr -d ' \t"')
      val=$(echo "$val" | sed -e 's/^["'\'']//' -e 's/["'\'']$//')
      case "$key" in
        DEFAULT_PROFILE) ADM_DEFAULT_PROFILE="$val" ;;
        MIRRORS) ADM_MIRRORS="$val" ;;
        DOWNLOAD_RETRY) ADM_DOWNLOAD_RETRY="$val" ;;
        MAKEJOBS) ADM_MAKEJOBS="$val" ;;
      esac
    done < <(grep -E '^[A-Z_]+=.*' "$ADM_PROFILE_FILE" 2>/dev/null || true)
  fi
  # set env defaults if empty
  : "${ADM_MIRRORS:=}"
  : "${ADM_DOWNLOAD_RETRY:=3}"
  : "${ADM_MAKEJOBS:=}"
}

export_env_vars() {
  export ADM_ROOT ADM_SCRIPTS ADM_ETC ADM_VAR ADM_LOG ADM_DB ADM_TMP ADM_META ADM_SRC ADM_UPDATE ADM_TARGET ADM_PROFILES_DIR
  export ADM_PROFILE_FILE ADM_DEFAULT_PROFILE ADM_MIRRORS ADM_DOWNLOAD_RETRY ADM_MAKEJOBS
}

sanity_checks() {
  # basic checks: ensure we can write to ADM_ROOT
  if [ ! -w "$(dirname "$ADM_ROOT")" ] && [ ! -d "$ADM_ROOT" ]; then
    echo "Warning: cannot create $ADM_ROOT automatically (no write permission in parent). Please run as a user that can create the directory." >&2
  fi
}

print_summary() {
  cat <<EOF
ADM environment prepared
  ADM_ROOT: $ADM_ROOT
  ADM_SCRIPTS: $ADM_SCRIPTS
  ADM_META: $ADM_META
  ADM_SRC: $ADM_SRC
  ADM_UPDATE: $ADM_UPDATE
  ADM_TARGET: $ADM_TARGET
  ADM_VAR: $ADM_VAR
  DEFAULT_PROFILE: ${ADM_DEFAULT_PROFILE}
  Current mode: ${ADM_MODE}
  Log file: ${ADM_LOG}
EOF
}

# ---------- CLI ----------
usage() {
  cat <<EOF
env.sh - environment initializer for ADM
Usage (intended to be called by installer or manually)
  env.sh init       # create directories, defaults and export env
  env.sh status     # print environment summary
  env.sh export     # print export lines for shell evaluation
EOF
}

cmd_init() {
  ensure_tree
  detect_mode
  load_profile_defaults
  create_adm_conf
  load_adm_conf
  export_env_vars
  sanity_checks
  printf "ADM environment created/validated at %s\n" "$ADM_ROOT"
  print_summary
}

cmd_status() {
  detect_mode
  load_adm_conf
  export_env_vars
  print_summary
}

cmd_export() {
  # prints shell exports so the caller may eval it: eval "$(env.sh export)"
  printf "export ADM_ROOT='%s'\n" "$ADM_ROOT"
  printf "export ADM_SCRIPTS='%s'\n" "$ADM_SCRIPTS"
  printf "export ADM_META='%s'\n" "$ADM_META"
  printf "export ADM_SRC='%s'\n" "$ADM_SRC"
  printf "export ADM_UPDATE='%s'\n" "$ADM_UPDATE"
  printf "export ADM_TARGET='%s'\n" "$ADM_TARGET"
  printf "export ADM_VAR='%s'\n" "$ADM_VAR"
  printf "export ADM_LOG='%s'\n" "$ADM_LOG"
  printf "export ADM_DEFAULT_PROFILE='%s'\n" "$ADM_DEFAULT_PROFILE"
}

_main() {
  if [ $# -lt 1 ]; then usage; exit 0; fi
  case "$1" in
    init) cmd_init; exit 0;;
    status) cmd_status; exit 0;;
    export) cmd_export; exit 0;;
    help|-h|--help) usage; exit 0;;
    *) echo "Unknown command: $1"; usage; exit 2;;
  esac
}

# run main when executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _main "$@"
fi
