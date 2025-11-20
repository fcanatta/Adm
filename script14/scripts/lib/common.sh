#!/usr/bin/env bash
# shellcheck shell=bash
#
# Funções utilitárias comuns.

set -Eeuo pipefail

# Carrega log se disponível
if [[ -z "${ADM_LIB_LOG_LOADED:-}" ]]; then
  if [[ -r "/usr/src/adm/scripts/lib/log.sh" ]]; then
    # shellcheck source=/usr/src/adm/scripts/lib/log.sh
    . "/usr/src/adm/scripts/lib/log.sh"
    ADM_LIB_LOG_LOADED=1
  fi
fi

adm_die() {
  local code="${1:-1}"; shift || true
  local msg="${*:-Erro inesperado}"
  if command -v log_error >/dev/null 2>&1; then
    log_error "$msg"
  else
    echo "ERRO: $msg" >&2
  fi
  exit "$code"
}

adm_require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    adm_die 1 "Este script precisa ser executado como root."
  fi
}

adm_check_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    adm_die 1 "Comando obrigatório não encontrado: $cmd"
  fi
}

adm_abspath() {
  # Versão POSIX-ish de realpath
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
  fi
}

adm_read_config_var() {
  local file="$1" key="$2"
  [[ -r "$file" ]] || return 1
  # ignora comentários e espaços
  awk -F= -v k="$key" '
    $0 !~ /^[[:space:]]*#/ && $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
      sub(/^[[:space:]]+/, "", $2);
      sub(/[[:space:]]+$/, "", $2);
      print $2; exit 0
    }' "$file"
}

adm_mkdir_safe() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    log_info "Criado diretório: $dir"
  fi
}
