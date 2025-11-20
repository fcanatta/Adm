#!/usr/bin/env bash
# shellcheck shell=bash
#
# Biblioteca de logging para todo o sistema ADM.

# Diretório e arquivo padrão de log (podem ser sobrescritos)
ADM_LOG_DIR_DEFAULT="${ADM_LOG_DIR_DEFAULT:-/usr/src/adm/logs}"
ADM_LOG_FILE_DEFAULT="${ADM_LOG_FILE_DEFAULT:-adm.log}"

# Flag para desabilitar cores (export ADM_NO_COLOR=1)
ADM_NO_COLOR="${ADM_NO_COLOR:-0}"

# Cores ANSI
if [[ "$ADM_NO_COLOR" -eq 0 ]]; then
  _CLR_RESET="\033[0m"
  _CLR_INFO="\033[1;34m"
  _CLR_WARN="\033[1;33m"
  _CLR_ERROR="\033[1;31m"
  _CLR_TASK="\033[1;36m"
  _CLR_OK="\033[1;32m"
else
  _CLR_RESET=""
  _CLR_INFO=""
  _CLR_WARN=""
  _CLR_ERROR=""
  _CLR_TASK=""
  _CLR_OK=""
fi

_adm_ts() {
  date +"%Y-%m-%d %H:%M:%S"
}

adm_log_init() {
  local log_dir="${1:-$ADM_LOG_DIR_DEFAULT}"
  local log_file="${2:-$ADM_LOG_FILE_DEFAULT}"

  mkdir -p "$log_dir"
  ADM_LOG_PATH="$log_dir/$log_file"

  # Não trunca se já existir; apenas garante que dá para escrever
  if ! : >>"$ADM_LOG_PATH"; then
    echo "ERRO: não foi possível escrever em '$ADM_LOG_PATH'" >&2
    return 1
  fi
}

adm_log_raw() {
  local level="$1"; shift
  local msg="$*"

  [[ -z "${ADM_LOG_PATH:-}" ]] && ADM_LOG_PATH="$ADM_LOG_DIR_DEFAULT/$ADM_LOG_FILE_DEFAULT"

  local ts
  ts="$(_adm_ts)"
  local line="[$ts] [$level] $msg"

  # log em arquivo (sem cores)
  mkdir -p "$(dirname "$ADM_LOG_PATH")"
  printf '%s\n' "$line" >>"$ADM_LOG_PATH"

  # log em stdout (com cores)
  case "$level" in
    INFO)  printf "${_CLR_INFO}%s${_CLR_RESET}\n"  "$line" ;;
    WARN)  printf "${_CLR_WARN}%s${_CLR_RESET}\n"  "$line" ;;
    ERROR) printf "${_CLR_ERROR}%s${_CLR_RESET}\n" "$line" ;;
    TASK)  printf "${_CLR_TASK}%s${_CLR_RESET}\n"  "$line" ;;
    OK)    printf "${_CLR_OK}%s${_CLR_RESET}\n"    "$line" ;;
    *)     printf "%s\n" "$line" ;;
  esac
}

log_info()  { adm_log_raw "INFO"  "$*"; }
log_warn()  { adm_log_raw "WARN"  "$*"; }
log_error() { adm_log_raw "ERROR" "$*"; }

# Controle de tarefas
_ADM_CURRENT_TASK=""

task_start() {
  _ADM_CURRENT_TASK="$*"
  adm_log_raw "TASK" "Iniciando: $_ADM_CURRENT_TASK"
}

task_ok() {
  local msg="${*:-Concluído}"
  if [[ -n "$_ADM_CURRENT_TASK" ]]; then
    adm_log_raw "OK" "OK: $_ADM_CURRENT_TASK - $msg"
    _ADM_CURRENT_TASK=""
  else
    adm_log_raw "OK" "$msg"
  fi
}

task_fail() {
  local msg="${*:-Falhou}"
  if [[ -n "$_ADM_CURRENT_TASK" ]]; then
    adm_log_raw "ERROR" "FALHA: $_ADM_CURRENT_TASK - $msg"
    _ADM_CURRENT_TASK=""
  else
    adm_log_raw "ERROR" "$msg"
  fi
}
