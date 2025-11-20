#!/usr/bin/env bash
# shellcheck shell=bash

set -Eeuo pipefail

ROOT_DIR="/usr/src/adm"
SCRIPTS_DIR="$ROOT_DIR/scripts"
LOGS_DIR="$ROOT_DIR/logs"

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "$SCRIPTS_DIR/lib/common.sh"

LOG_MAX_SIZE_BYTES="${LOG_MAX_SIZE_BYTES:-5242880}"  # 5 MB

main() {
  adm_require_root
  adm_mkdir_safe "$LOGS_DIR"

  adm_log_init "$LOGS_DIR" "log-manager.log"
  task_start "Gerenciamento de logs em $LOGS_DIR"

  rotate_logs
  create_log_index

  task_ok "Log manager concluído."
}

rotate_logs() {
  log_info "Verificando necessidade de rotação de logs em $LOGS_DIR"

  local f size
  for f in "$LOGS_DIR"/*.log; do
    [[ -e "$f" ]] || continue
    size=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    if (( size > LOG_MAX_SIZE_BYTES )); then
      local ts
      ts="$(date +"%Y%m%d-%H%M%S")"
      local rotated="${f}.${ts}.gz"
      log_info "Rotacionando log: $f -> $rotated"
      gzip -c "$f" >"$rotated"
      : >"$f"
    fi
  done
}

create_log_index() {
  local index_file="$LOGS_DIR/index.txt"
  log_info "Atualizando índice de logs em $index_file"

  {
    echo "# Índice de logs do ADM"
    echo "# Atualizado em $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo

    ls -1 "$LOGS_DIR" | sort
  } >"$index_file"
}

main "$@"
