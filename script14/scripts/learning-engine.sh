#!/usr/bin/env bash
# shellcheck shell=bash
#
# learning-engine.sh
# Interface de alto nível para a base de inteligência (intelligence.db).
#
# Uso:
#   learning-engine.sh record-start <pkg> <ver> <profile> <flags> <log_path>
#   learning-engine.sh record-end   <pkg> <status> <duration_sec>
#   learning-engine.sh last-status  <pkg>
#   learning-engine.sh report       [pkg]

set -Eeuo pipefail

ROOT_DIR="/usr/src/adm"
SCRIPTS_DIR="$ROOT_DIR/scripts"

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "$SCRIPTS_DIR/lib/common.sh"
# shellcheck source=/usr/src/adm/scripts/lib/db-intelligence.sh
. "$SCRIPTS_DIR/lib/db-intelligence.sh"
# shellcheck source=/usr/src/adm/scripts/lib/meta.sh
. "$SCRIPTS_DIR/lib/meta.sh"

usage() {
  cat <<EOF
Uso:
  learning-engine.sh record-start <pkg> <ver> <profile> <flags> <log_path>
  learning-engine.sh record-end   <pkg> <status> <duration_sec>
  learning-engine.sh last-status  <pkg>
  learning-engine.sh report       [pkg]

Status típicos:
  success, fail, partial
EOF
}

record_start() {
  local pkg="$1" ver="$2" profile="$3" flags="$4" log_path="$5"
  log_info "Registrando início de build: $pkg $ver ($profile)"
  adm_intel_record_build_start "$pkg" "$ver" "$profile" "$flags" "$log_path"
}

record_end() {
  local pkg="$1" status="$2" dur="$3"
  log_info "Registrando fim de build: $pkg status=$status dur=${dur}s"
  adm_intel_record_build_end "$pkg" "$status" "$dur"
}

last_status() {
  local pkg="$1"
  local st
  st="$(adm_intel_last_status "$pkg" 2>/dev/null || echo "unknown")"
  printf '%s\n' "$st"
}

report() {
  local pkg_filter="${1:-}"

  if ! command -v sqlite3 >/dev/null 2>&1; then
    adm_die 1 "sqlite3 não disponível; não é possível gerar relatório."
  fi

  adm_intel_init

  local sql
  if [[ -n "$pkg_filter" ]]; then
    sql="SELECT package,version,profile,status,duration_sec,started_at,finished_at
         FROM builds
         WHERE package='$pkg_filter'
         ORDER BY id DESC LIMIT 20;"
  else
    sql="SELECT package,version,profile,status,duration_sec,started_at,finished_at
         FROM builds
         ORDER BY id DESC LIMIT 50;"
  fi

  log_info "Gerando relatório de builds (filtro: ${pkg_filter:-todos})"

  sqlite3 -header -column "$ADM_INTEL_DB" "$sql" | sed 's/|/  |  /g'
}

main() {
  adm_log_init "$ROOT_DIR/logs" "learning-engine.log"

  local cmd="${1:-}"
  case "$cmd" in
    record-start)
      (($# == 6)) || { usage; adm_die 1 "Parâmetros inválidos."; }
      record_start "$2" "$3" "$4" "$5" "$6"
      ;;
    record-end)
      (($# == 4)) || { usage; adm_die 1 "Parâmetros inválidos."; }
      record_end "$2" "$3" "$4"
      ;;
    last-status)
      (($# == 2)) || { usage; adm_die 1 "Informe o pacote."; }
      last_status "$2"
      ;;
    report)
      if (($# == 2)); then
        report "$2"
      else
        report
      fi
      ;;
    ""|-h|--help)
      usage
      ;;
    *)
      usage
      adm_die 1 "Comando desconhecido: $cmd"
      ;;
  esac
}

main "$@"
