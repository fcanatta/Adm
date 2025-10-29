#!/bin/bash
#============================================================
# ui.sh — Interface visual e feedback de build
# ADM Build System v1.0
#============================================================

# Carregar ambiente e log
source /usr/src/adm/scripts/env.sh
source /usr/src/adm/scripts/log.sh

#============================================================
# Cores e formatação
#============================================================
if [[ -t 1 ]]; then
    COLOR_RESET="\033[0m"
    COLOR_BOLD="\033[1m"
    COLOR_BLUE_BOLD="\033[1;34m"
    COLOR_GREEN="\033[1;32m"
    COLOR_RED="\033[1;31m"
    COLOR_YELLOW="\033[1;33m"
    COLOR_MAGENTA="\033[1;35m"  # rosa/roxo para cabeçalho
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_BLUE_BOLD=""
    COLOR_GREEN=""
    COLOR_RED=""
    COLOR_YELLOW=""
    COLOR_MAGENTA=""
fi

#============================================================
# Cabeçalho principal
#============================================================
ui_header() {
    local name="${ADM_PKG_NAME:-Desconhecido}"
    local version="${ADM_PKG_VERSION:-N/A}"
    local profile="${ADM_PROFILE:-normal}"
    local cores
    cores=$(nproc 2>/dev/null || echo 1)
    local date_time
    date_time="$(date '+%Y-%m-%d %H:%M:%S')"

    clear
    echo -e "${COLOR_MAGENTA}${COLOR_BOLD}╔══════════════════════════════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_MAGENTA}${COLOR_BOLD}║ 💠  ADM Build System v1.0                                            ║${COLOR_RESET}"
    printf "${COLOR_MAGENTA}${COLOR_BOLD}║ Programa:${COLOR_RESET} %s %s  |  Profile: %s  |  Núcleos: %s\n" \
        "${name}" "${version}" "${profile}" "${cores}"
    printf "${COLOR_MAGENTA}${COLOR_BOLD}║ Iniciado: %s  |  Diretório: %s\n" "${date_time}" "${PWD}"
    echo -e "${COLOR_MAGENTA}${COLOR_BOLD}╚══════════════════════════════════════════════════════════════════════╝${COLOR_RESET}"
}

#============================================================
# Spinner e progresso
#============================================================
_spinner_pid=0

ui_start_spinner() {
    local msg="$1"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    printf "${COLOR_BLUE_BOLD}[ ] %s${COLOR_RESET}\r" "$msg"
    (
        while true; do
            i=$(( (i + 1) % 10 ))
            printf "${COLOR_BLUE_BOLD}[%s] %s${COLOR_RESET}\r" "${spin:$i:1}" "$msg"
            sleep 0.1
        done
    ) &
    _spinner_pid=$!
}

ui_stop_spinner() {
    local status=$1
    local msg="$2"

    if [[ $_spinner_pid -ne 0 ]]; then
        kill "$_spinner_pid" 2>/dev/null
        wait "$_spinner_pid" 2>/dev/null
        _spinner_pid=0
    fi

    if [[ $status -eq 0 ]]; then
        printf "${COLOR_GREEN}[✔️] %s... concluído${COLOR_RESET}\n" "$msg"
    else
        printf "${COLOR_RED}[✖] %s... falhou${COLOR_RESET}\n" "$msg"
    fi
}

#============================================================
# Seções visuais (integra com log_section)
#============================================================
ui_section() {
    local title="$1"
    log_section "$title"
    ui_start_spinner "$title"
}

ui_end_section() {
    local status=$1
    local title="$2"
    ui_stop_spinner "$status" "$title"
}

#============================================================
# Finalização e resumo
#============================================================
ui_summary() {
    local name="${ADM_PKG_NAME:-Desconhecido}"
    local version="${ADM_PKG_VERSION:-N/A}"
    local profile="${ADM_PROFILE:-normal}"
    local log_file="${ADM_LOG_FILE:-/usr/src/adm/logs/unknown.log}"
    local duration="${ADM_BUILD_DURATION:-N/A}"

    echo -e "\n${COLOR_MAGENTA}${COLOR_BOLD}╔══════════════════════════════════════════════════════════════════════╗${COLOR_RESET}"
    printf "${COLOR_MAGENTA}${COLOR_BOLD}║ 🧱  %s %s  —  Profile: %s\n" "${name}" "${version}" "${profile}"
    printf "${COLOR_MAGENTA}${COLOR_BOLD}║ Status:${COLOR_RESET} ✅ Sucesso   |   Tempo: %s\n" "${duration}"
    printf "${COLOR_MAGENTA}${COLOR_BOLD}║ Log salvo em:${COLOR_RESET} %s\n" "${log_file}"
    echo -e "${COLOR_MAGENTA}${COLOR_BOLD}╚══════════════════════════════════════════════════════════════════════╝${COLOR_RESET}"
}

#============================================================
# Exemplo de uso (para integração futura)
#============================================================
# ui_header
# ui_section "Preparando ambiente"
# sleep 2
# ui_end_section 0 "Preparando ambiente"
# ui_summary
