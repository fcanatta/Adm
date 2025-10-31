#!/usr/bin/env bash
#=============================================================
#  ui.sh — Interface visual do ADM Build System
#-------------------------------------------------------------
#  Exibe status dinâmico, progresso e métricas do sistema
#  durante a construção de pacotes.
#
#  - Mostra header com logo, versão e status atual
#  - Exibe fila de pacotes com spinner no ativo
#  - Monitora CPU, memória e load average em tempo real
#  - Resumo final após conclusão
#
#  Uso:
#     source /usr/src/adm/scripts/ui.sh
#     bash ui.sh --test     # modo demonstração
#=============================================================

[[ -n "${ADM_UI_SH_LOADED}" ]] && return
ADM_UI_SH_LOADED=1

#-------------------------------------------------------------
#  Dependências
#-------------------------------------------------------------
source /usr/src/adm/scripts/colors.sh
source /usr/src/adm/scripts/log.sh
source /usr/src/adm/scripts/env.sh

#-------------------------------------------------------------
#  Variáveis globais e símbolos
#-------------------------------------------------------------
UI_NAME="ADM Build System"
UI_VERSION="v1.0"
UI_SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
UI_SYMBOL_OK="✔"
UI_SYMBOL_FAIL="✖"
UI_WIDTH=$(tput cols)
UI_REFRESH=0.1

#-------------------------------------------------------------
#  Funções principais de renderização
#-------------------------------------------------------------

ui_draw_header() {
    local current_pkg="$1"
    local step="$2"
    clear
    echo -e "${BRIGHT_BLUE}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    printf "║ %-54s ║\n" "${UI_NAME} ${UI_VERSION}  •  Running: ${current_pkg:-none} (${step:-idle})"
    printf "║ %-54s ║\n" "Host: $(hostname)  •  $(date '+%Y-%m-%d  %H:%M:%S')"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

ui_draw_queue() {
    local active="$1"
    local done_list=("${!2}")
    local pending_list=("${!3}")
    local frame="${UI_SPINNER_FRAMES[$((RANDOM % ${#UI_SPINNER_FRAMES[@]}))]}"
    local output=""

    for pkg in "${done_list[@]}"; do
        output+="[${GREEN}${UI_SYMBOL_OK}${RESET}] ${pkg}   "
    done
    [[ -n "$active" ]] && output+="[${YELLOW}${frame}${RESET}] ${active}   "
    for pkg in "${pending_list[@]}"; do
        output+="[${BRIGHT_BLACK} ${RESET}] ${pkg}   "
    done
    echo -e "$output"
}

ui_draw_progress() {
    local pkg="$1"
    local step="$2"
    local percent="$3"
    local elapsed="$4"
    local frame="${UI_SPINNER_FRAMES[$((RANDOM % ${#UI_SPINNER_FRAMES[@]}))]}"

    echo -e "\n${BRIGHT_CYAN}${frame}${RESET} ${BOLD}${pkg}${RESET} | Etapa: ${step} | ${YELLOW}${percent}%%${RESET} | ⏱ ${elapsed}s"
    echo -e "${BRIGHT_BLACK}────────────────────────────────────────────────────────────${RESET}"
}

ui_draw_footer() {
    local cpu mem_total mem_free mem_used load
    cpu=$(awk '/cpu /{u=($2+$4)*100/($2+$4+$5); printf("%.1f%%", u)}' /proc/stat)
    mem_total=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    mem_free=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    mem_used=$((mem_total - mem_free))
    load=$(awk '{print $1" "$2" "$3}' /proc/loadavg)

    echo -e "${BRIGHT_BLACK}────────────────────────────────────────────────────────────${RESET}"
    echo -e "CPU: ${BRIGHT_GREEN}${cpu}${RESET}  MEM: ${BRIGHT_YELLOW}${mem_used}MB/${mem_total}MB${RESET}  LOAD: ${CYAN}${load}${RESET}"
    echo -e "${BRIGHT_BLACK}────────────────────────────────────────────────────────────${RESET}"
}

ui_summary() {
    local total="$1"
    local success="$2"
    local failed="$3"
    echo -e "\n${BOLD}${BRIGHT_BLUE}=== RESUMO FINAL ===${RESET}"
    echo -e "${GREEN}✔ Sucesso:${RESET} ${success}"
    echo -e "${RED}✖ Falhas:${RESET}  ${failed}"
    echo -e "${CYAN}ℹ Total:${RESET}   ${total}"
    echo -e "${DIM}Logs em:${RESET} ${ADM_LOG_DIR}\n"
}

#-------------------------------------------------------------
#  Demonstração visual (modo teste)
#-------------------------------------------------------------
if [[ "$1" == "--test" ]]; then
    local done_list=()
    local pending_list=("zlib-1.3.1" "openssl-3.2.1" "curl-8.9.0")

    for pkg in "${pending_list[@]}"; do
        ui_draw_header "$pkg" "build"
        ui_draw_queue "$pkg" done_list[@] pending_list[@]
        local start=$(date +%s)
        for i in $(seq 0 100 5); do
            local elapsed=$(( $(date +%s) - start ))
            ui_draw_progress "$pkg" "build" "$i" "$elapsed"
            sleep $UI_REFRESH
            tput cup $(($(tput lines)-4)) 0
            ui_draw_footer
        done
        echo -e "\n${GREEN}${UI_SYMBOL_OK}${RESET} ${pkg} concluído com sucesso!"
        done_list+=("$pkg")
        pending_list=("${pending_list[@]:1}")
        sleep 0.8
    done

    ui_summary 3 3 0
fi
