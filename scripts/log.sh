#!/usr/bin/env bash
#=============================================================
#  log.sh — Sistema de logging padronizado do ADM Build System
#-------------------------------------------------------------
#  Responsável por registrar mensagens coloridas e formatadas
#  no terminal e em arquivos de log persistentes.
#
#  Este módulo deve ser carregado via:
#     source /usr/src/adm/scripts/log.sh
#
#  Uso básico:
#     log_init
#     log_info "Mensagem informativa"
#     log_warn "Aviso importante"
#     log_error "Erro crítico"
#     log_success "Operação concluída"
#     log_debug "Mensagem de depuração"
#
#  O log é gravado em:
#     /usr/src/adm/logs/adm-YYYYMMDD-HHMMSS.log
#=============================================================
#-------------------------------------------------------------
#  Proteção contra múltiplas inclusões
#-------------------------------------------------------------
[[ -n "${ADM_LOG_SH_LOADED}" ]] && return
ADM_LOG_SH_LOADED=1

#-------------------------------------------------------------
#  Impedir execução direta
#-------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "❌ Este script não deve ser executado diretamente."
    echo "   Use: source /usr/src/adm/scripts/log.sh"
    exit 1
fi

#-------------------------------------------------------------
#  Importar módulo de cores
#-------------------------------------------------------------
source /usr/src/adm/scripts/colors.sh

#-------------------------------------------------------------
#  Diretórios e variáveis padrão
#-------------------------------------------------------------
ADM_LOG_DIR="/usr/src/adm/logs"
mkdir -p "${ADM_LOG_DIR}" 2>/dev/null

ADM_LOG_FILE="${ADM_LOG_DIR}/adm-$(date +%Y%m%d-%H%M%S).log"
ADM_LOG_LEVEL="${ADM_LOG_LEVEL:-INFO}"   # Pode ser INFO ou DEBUG

#-------------------------------------------------------------
#  Funções internas
#-------------------------------------------------------------
log_timestamp() {
    date +"[%Y-%m-%d %H:%M:%S]"
}

#-------------------------------------------------------------
#  Funções principais de log
#-------------------------------------------------------------
log_info() {
    local msg="$*"
    echo -e "$(log_timestamp) ${BLUE}[INFO]${RESET} ${msg}" | tee -a "$ADM_LOG_FILE"
}

log_warn() {
    local msg="$*"
    echo -e "$(log_timestamp) ${YELLOW}[WARN]${RESET} ${msg}" | tee -a "$ADM_LOG_FILE"
}

log_error() {
    local msg="$*"
    echo -e "$(log_timestamp) ${RED}[ERROR]${RESET} ${msg}" | tee -a "$ADM_LOG_FILE" >&2
}

log_success() {
    local msg="$*"
    echo -e "$(log_timestamp) ${GREEN}[ OK ]${RESET} ${msg}" | tee -a "$ADM_LOG_FILE"
}

log_debug() {
    [[ "$ADM_LOG_LEVEL" == "DEBUG" ]] || return 0
    local msg="$*"
    echo -e "$(log_timestamp) ${BRIGHT_BLACK}[DBG]${RESET} ${msg}" | tee -a "$ADM_LOG_FILE"
}

#-------------------------------------------------------------
#  Funções auxiliares
#-------------------------------------------------------------
log_init() {
    mkdir -p "$ADM_LOG_DIR"
    ADM_LOG_FILE="${ADM_LOG_DIR}/adm-$(date +%Y%m%d-%H%M%S).log"
    log_info "Log inicializado: $ADM_LOG_FILE"
}

log_setfile() {
    [[ -z "$1" ]] && { log_error "Uso: log_setfile <arquivo>"; return 1; }
    ADM_LOG_FILE="$1"
    log_info "Arquivo de log alterado para: $ADM_LOG_FILE"
}

log_section() {
    local title="$*"
    echo -e "${BOLD}${BRIGHT_BLUE}========== ${title} ==========${RESET}" | tee -a "$ADM_LOG_FILE"
}

log_close() {
    log_info "Encerrando log."
    echo -e "${DIM}Logs salvos em: ${ADM_LOG_FILE}${RESET}"
}

#-------------------------------------------------------------
#  Função de teste (execução manual)
#-------------------------------------------------------------
if [[ "${1}" == "--test" ]]; then
    echo -e "\n${BOLD}${BRIGHT_BLUE}=== Teste do sistema de logs ADM Build ===${RESET}\n"
    log_init
    log_info    "Iniciando teste de log..."
    log_warn    "Este é um aviso de exemplo."
    log_error   "Esta é uma mensagem de erro simulada."
    log_success "Teste de sucesso concluído."
    ADM_LOG_LEVEL="DEBUG"
    log_debug   "Mensagem de depuração (visível apenas em modo DEBUG)."
    log_section "Seção de Demonstração"
    log_close
    echo -e "\n${BRIGHT_GREEN}✔ Teste concluído. Verifique o log em:${RESET} ${ADM_LOG_FILE}\n"
fi
