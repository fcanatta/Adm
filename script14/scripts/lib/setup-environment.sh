#!/usr/bin/env bash
# shellcheck shell=bash

set -Eeuo pipefail

ROOT_DIR="/usr/src/adm"
SCRIPTS_DIR="$ROOT_DIR/scripts"
LOGS_DIR="$ROOT_DIR/logs"

# Carrega libs
# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "$SCRIPTS_DIR/lib/common.sh"
# shellcheck source=/usr/src/adm/scripts/lib/meta.sh
. "$SCRIPTS_DIR/lib/meta.sh"

main() {
  adm_require_root

  adm_mkdir_safe "$ROOT_DIR"
  adm_mkdir_safe "$SCRIPTS_DIR"
  adm_mkdir_safe "$ROOT_DIR/repo"
  adm_mkdir_safe "$ROOT_DIR/sources"
  adm_mkdir_safe "$ROOT_DIR/build"
  adm_mkdir_safe "$ROOT_DIR/cache"
  adm_mkdir_safe "$LOGS_DIR"
  adm_mkdir_safe "$ROOT_DIR/intelligence"
  adm_mkdir_safe "$ROOT_DIR/profiles"

  adm_log_init "$LOGS_DIR" "setup-environment.log"
  task_start "Inicializando ambiente ADM em $ROOT_DIR"

  create_hardware_info
  create_global_env
  create_default_profiles

  task_ok "Ambiente inicializado com sucesso."
}

create_hardware_info() {
  local hw_file="$ROOT_DIR/hardware.info"
  log_info "Coletando informações de hardware em $hw_file"

  {
    echo "# Informações de hardware geradas por setup-environment.sh"
    echo "timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo

    if command -v lscpu >/dev/null 2>&1; then
      echo "[lscpu]"
      lscpu
      echo
    fi

    if command -v lsblk >/dev/null 2>&1; then
      echo "[lsblk]"
      lsblk
      echo
    fi

    if command -v free >/dev/null 2>&1; then
      echo "[memoria]"
      free -h
      echo
    fi

  } >"$hw_file"

  adm_meta_set "hardware.info.path" "$hw_file"
}

create_global_env() {
  local env_file="$ROOT_DIR/global-env.sh"
  log_info "Criando arquivo de ambiente global em $env_file"

  cat >"$env_file" <<'EOF'
# Ambiente global do sistema ADM

export ADM_ROOT="/usr/src/adm"
export ADM_SCRIPTS="$ADM_ROOT/scripts"
export ADM_SOURCES="$ADM_ROOT/sources"
export ADM_BUILD="$ADM_ROOT/build"
export ADM_CACHE="$ADM_ROOT/cache"
export ADM_LOGS="$ADM_ROOT/logs"
export ADM_META="$ADM_ROOT/meta"
export ADM_INTEL="$ADM_ROOT/intelligence"
export ADM_PROFILES="$ADM_ROOT/profiles"

# Ajustes mínimos de PATH (podem ser refinados por environment-wrapper.sh)
export PATH="$ADM_SCRIPTS:$PATH"
EOF

  adm_meta_set "global-env.path" "$env_file"
}

create_default_profiles() {
  log_info "Criando perfis básicos em $ROOT_DIR/profiles"

  cat >"$ROOT_DIR/profiles/minimal.profile" <<'EOF'
# Perfil: minimal
LIBC=musl
INIT=sysvinit
OPT_LEVEL=O2
FEATURES="base,cli"
EOF

  cat >"$ROOT_DIR/profiles/desktop.profile" <<'EOF'
# Perfil: desktop
LIBC=glibc
INIT=systemd
OPT_LEVEL=O2
FEATURES="base,cli,gui"
EOF

  cat >"$ROOT_DIR/profiles/server.profile" <<'EOF'
# Perfil: server
LIBC=glibc
INIT=systemd
OPT_LEVEL=O2
FEATURES="base,cli,server"
EOF

  adm_meta_set "profiles.list" "minimal,desktop,server"
}

main "$@"
