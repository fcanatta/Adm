#!/usr/bin/env bash
# shellcheck shell=bash
#
# Verifica dependências do host necessárias para o ADM.

set -Eeuo pipefail

ROOT_DIR="/usr/src/adm"
SCRIPTS_DIR="$ROOT_DIR/scripts"
LOGS_DIR="$ROOT_DIR/logs"

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "$SCRIPTS_DIR/lib/common.sh"
# shellcheck source=/usr/src/adm/scripts/lib/meta.sh
. "$SCRIPTS_DIR/lib/meta.sh"

# Lista base de comandos obrigatórios
REQUIRED_CMDS=(
  bash
  awk
  sed
  grep
  tar
  gzip
  xz
  curl
  wget
  git
  make
  gcc
  ld
)

# Comandos recomendados (não fatais, mas avisam)
RECOMMENDED_CMDS=(
  lscpu
  lsblk
  free
  sqlite3
  python3
  qemu-system-x86_64
)

REPORT_FILE="$LOGS_DIR/deps-report.txt"

main() {
  adm_require_root
  adm_mkdir_safe "$LOGS_DIR"

  adm_log_init "$LOGS_DIR" "verify-dependencies.log"
  task_start "Verificando dependências do host"

  local missing_required=()
  local missing_recommended=()

  check_cmd_list "Obrigatórios"   REQUIRED_CMDS[@]   missing_required
  check_cmd_list "Recomendados"   RECOMMENDED_CMDS[@] missing_recommended

  write_report missing_required[@] missing_recommended[@]

  if ((${#missing_required[@]} > 0)); then
    task_fail "Dependências obrigatórias ausentes."
    echo
    echo "Algumas dependências obrigatórias estão faltando. Consulte:"
    echo "  $REPORT_FILE"
    exit 1
  else
    task_ok "Todas as dependências obrigatórias estão presentes."
  fi
}

check_cmd_list() {
  local title="$1"
  local -a list=("${!2}")
  local -n out_missing="$3"

  log_info "Verificando comandos: $title"

  local cmd
  for cmd in "${list[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      log_info "OK: $cmd"
    else
      log_warn "FALTANDO: $cmd"
      out_missing+=("$cmd")
    fi
  done
}

write_report() {
  local -a missing_required=("${!1}")
  local -a missing_recommended=("${!2}")

  log_info "Escrevendo relatório de dependências em $REPORT_FILE"

  {
    echo "# Relatório de dependências do host"
    echo "# Gerado por verify-dependencies.sh em $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo

    echo "[Obrigatórios faltando]"
    if ((${#missing_required[@]} == 0)); then
      echo "OK - Nenhum faltando"
    else
      printf '%s\n' "${missing_required[@]}"
    fi
    echo

    echo "[Recomendados faltando]"
    if ((${#missing_recommended[@]} == 0)); then
      echo "OK - Nenhum faltando"
    else
      printf '%s\n' "${missing_recommended[@]}"
    fi
  } >"$REPORT_FILE"

  adm_meta_set "deps-report.path" "$REPORT_FILE"
}

main "$@"
