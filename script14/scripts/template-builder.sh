#!/usr/bin/env bash
# shellcheck shell=bash
#
# Gera "templates" de build a partir de um perfil base.
# Exemplo de saída:
#   meta/templates/<perfil>-glibc-systemd.template
#   meta/templates/<perfil>-musl-sysvinit.template
#
# Cada template descreve:
#   LIBC=...
#   INIT=...
#   OPT_LEVEL=...
#   FEATURE_LIST=...

set -Eeuo pipefail

ROOT_DIR="/usr/src/adm"
SCRIPTS_DIR="$ROOT_DIR/scripts"
PROFILES_DIR="$ROOT_DIR/profiles"

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "$SCRIPTS_DIR/lib/common.sh"
# shellcheck source=/usr/src/adm/scripts/lib/meta.sh
. "$SCRIPTS_DIR/lib/meta.sh"

TEMPLATES_DIR="$ROOT_DIR/meta/templates"

usage() {
  cat <<EOF
Uso: template-builder.sh <comando> [arg]

Comandos:
  generate-all            Gera templates para todos os perfis
  generate <perfil>       Gera templates para um perfil específico
  list                    Lista templates existentes
EOF
}

template_dir_init() {
  adm_mkdir_safe "$TEMPLATES_DIR"
}

generate_for_profile() {
  local profile="$1"
  local file="$PROFILES_DIR/${profile}.profile"

  if [[ ! -r "$file" ]]; then
    adm_die 1 "Perfil '$profile' não encontrado em $file"
  fi

  log_info "Gerando templates para perfil: $profile"

  # Carrega variáveis do perfil base
  # shellcheck disable=SC1090
  . "$file"

  local libc init opt features
  libc="${LIBC:-glibc}"
  init="${INIT:-systemd}"
  opt="${OPT_LEVEL:-O2}"
  features="${FEATURES:-base}"

  # Template padrão: o próprio perfil
  write_template "$profile" "$libc" "$init" "$opt" "$features"

  # Pode-se gerar variações combinando configs
  # Exemplo simples: trocar INIT ou LIBC para exploração
  if [[ "$libc" = "glibc" ]]; then
    write_template "${profile}-musl" "musl" "$init" "$opt" "$features"
  fi

  if [[ "$init" = "systemd" ]]; then
    write_template "${profile}-sysvinit" "$libc" "sysvinit" "$opt" "$features"
    write_template "${profile}-runit"    "$libc" "runit"    "$opt" "$features"
  fi
}

write_template() {
  local name="$1"
  local libc="$2"
  local init="$3"
  local opt="$4"
  local features="$5"

  template_dir_init

  local path="$TEMPLATES_DIR/${name}.template"
  log_info "Criando template: $path"

  cat >"$path" <<EOF
# Template de build: $name
LIBC="$libc"
INIT="$init"
OPT_LEVEL="$opt"
FEATURES="$features"
EOF
}

generate_all() {
  local f profile
  for f in "$PROFILES_DIR"/*.profile; do
    [[ -e "$f" ]] || continue
    profile="$(basename "$f" .profile)"
    generate_for_profile "$profile"
  done

  adm_meta_set "templates.dir" "$TEMPLATES_DIR"
}

list_templates() {
  template_dir_init
  local f
  for f in "$TEMPLATES_DIR"/*.template; do
    [[ -e "$f" ]] || continue
    basename "$f"
  done
}

main() {
  adm_log_init "$ROOT_DIR/logs" "template-builder.log"

  local cmd="${1:-}"
  case "$cmd" in
    generate-all)
      generate_all
      ;;
    generate)
      [[ $# -ge 2 ]] || adm_die 1 "Informe o perfil."
      generate_for_profile "$2"
      ;;
    list)
      list_templates
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
