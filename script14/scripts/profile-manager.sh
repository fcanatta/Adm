#!/usr/bin/env bash
# shellcheck shell=bash
#
# Gerencia perfis (minimal, desktop, server, embedded, extreme).
# - Lista perfis disponíveis
# - Mostra detalhes
# - Define perfil atual em meta/current-profile

set -Eeuo pipefail

ROOT_DIR="/usr/src/adm"
SCRIPTS_DIR="$ROOT_DIR/scripts"
PROFILES_DIR="$ROOT_DIR/profiles"

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "$SCRIPTS_DIR/lib/common.sh"
# shellcheck source=/usr/src/adm/scripts/lib/meta.sh
. "$SCRIPTS_DIR/lib/meta.sh"

usage() {
  cat <<EOF
Uso: profile-manager.sh <comando> [arg]

Comandos:
  list                 Lista perfis disponíveis
  show <nome>          Mostra detalhes de um perfil
  set  <nome>          Define perfil atual
  current              Mostra perfil atual
EOF
}

profile_list() {
  adm_mkdir_safe "$PROFILES_DIR"

  local f name
  for f in "$PROFILES_DIR"/*.profile; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f" .profile)"
    echo "$name"
  done
}

profile_show() {
  local name="$1"
  local file="$PROFILES_DIR/${name}.profile"

  if [[ ! -r "$file" ]]; then
    adm_die 1 "Perfil '$name' não encontrado em $file"
  fi

  echo "# Perfil: $name"
  cat "$file"
}

profile_set() {
  local name="$1"
  local file="$PROFILES_DIR/${name}.profile"

  if [[ ! -r "$file" ]]; then
    adm_die 1 "Perfil '$name' não encontrado em $file"
  fi

  adm_meta_set "current-profile" "$name"
  adm_meta_set "current-profile.path" "$file"
  log_info "Perfil atual definido: $name"
}

profile_current() {
  local name
  name="$(adm_meta_get current-profile 2>/dev/null || echo "não definido")"
  echo "$name"
}

main() {
  adm_log_init "$ROOT_DIR/logs" "profile-manager.log"

  local cmd="${1:-}"
  case "$cmd" in
    list)
      profile_list
      ;;
    show)
      [[ $# -ge 2 ]] || adm_die 1 "Informe o nome do perfil."
      profile_show "$2"
      ;;
    set)
      [[ $# -ge 2 ]] || adm_die 1 "Informe o nome do perfil."
      profile_set "$2"
      ;;
    current)
      profile_current
      ;;
    ""|-h|--help)
      usage
      ;;
    *)
      adm_die 1 "Comando desconhecido: $cmd"
      ;;
  esac
}

main "$@"
