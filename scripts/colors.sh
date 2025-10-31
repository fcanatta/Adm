#!/usr/bin/env bash
#=============================================================
#  colors.sh  —  Módulo de cores e estilos do ADM Build System
#-------------------------------------------------------------
#  Fornece códigos ANSI e funções padronizadas de cor.
#  Deve ser "sourceado" por outros scripts (não executado).
#=============================================================
#-------------------------------------------------------------
#  Proteção contra inclusão múltipla
#-------------------------------------------------------------
[[ -n "${ADM_COLORS_SH_LOADED}" ]] && return
ADM_COLORS_SH_LOADED=1

#-------------------------------------------------------------
#  Impedir execução direta
#-------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "❌ Este script não deve ser executado diretamente."
    echo "   Use: source /usr/src/adm/scripts/colors.sh"
    exit 1
fi

#-------------------------------------------------------------
#  Detectar se terminal suporta cores
#-------------------------------------------------------------
if [[ -t 1 && "$TERM" != "dumb" ]]; then
    SUPPORTS_COLOR=true
else
    SUPPORTS_COLOR=false
fi

#-------------------------------------------------------------
#  Definir códigos ANSI
#-------------------------------------------------------------
if $SUPPORTS_COLOR; then
    # Reset / estilos
    RESET="\033[0m"
    BOLD="\033[1m"
    DIM="\033[2m"
    UNDERLINE="\033[4m"
    INVERT="\033[7m"

    # Cores padrão
    BLACK="\033[30m"
    RED="\033[31m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    BLUE="\033[34m"
    MAGENTA="\033[35m"
    CYAN="\033[36m"
    WHITE="\033[37m"

    # Cores brilhantes
    BRIGHT_BLACK="\033[90m"
    BRIGHT_RED="\033[91m"
    BRIGHT_GREEN="\033[92m"
    BRIGHT_YELLOW="\033[93m"
    BRIGHT_BLUE="\033[94m"
    BRIGHT_MAGENTA="\033[95m"
    BRIGHT_CYAN="\033[96m"
    BRIGHT_WHITE="\033[97m"

    # Fundos
    BG_BLACK="\033[40m"
    BG_RED="\033[41m"
    BG_GREEN="\033[42m"
    BG_YELLOW="\033[43m"
    BG_BLUE="\033[44m"
    BG_MAGENTA="\033[45m"
    BG_CYAN="\033[46m"
    BG_WHITE="\033[47m"
else
    # Se não suportar cores, definir variáveis vazias
    RESET=""; BOLD=""; DIM=""; UNDERLINE=""; INVERT=""
    BLACK=""; RED=""; GREEN=""; YELLOW=""; BLUE=""
    MAGENTA=""; CYAN=""; WHITE=""
    BRIGHT_BLACK=""; BRIGHT_RED=""; BRIGHT_GREEN=""; BRIGHT_YELLOW=""
    BRIGHT_BLUE=""; BRIGHT_MAGENTA=""; BRIGHT_CYAN=""; BRIGHT_WHITE=""
    BG_BLACK=""; BG_RED=""; BG_GREEN=""; BG_YELLOW=""; BG_BLUE=""
    BG_MAGENTA=""; BG_CYAN=""; BG_WHITE=""
fi

#-------------------------------------------------------------
#  Funções utilitárias para mensagens coloridas
#-------------------------------------------------------------
color_info()    { echo -e "${BLUE}${1}${RESET}"; }
color_warn()    { echo -e "${YELLOW}${1}${RESET}"; }
color_error()   { echo -e "${RED}${1}${RESET}"; }
color_success() { echo -e "${GREEN}${1}${RESET}"; }
color_note()    { echo -e "${CYAN}${1}${RESET}"; }
color_title()   { echo -e "${BOLD}${BRIGHT_BLUE}${1}${RESET}"; }

#-------------------------------------------------------------
#  Exemplo de uso (caso testado manualmente)
#-------------------------------------------------------------
if [[ "${1}" == "--test" ]]; then
    echo -e "\n${BOLD}=== Teste de cores do ADM Build System ===${RESET}"
    color_info    "INFO: Processo iniciado..."
    color_warn    "WARN: Este é um aviso."
    color_error   "ERROR: Algo deu errado."
    color_success "OK: Processo concluído com sucesso!"
    color_note    "NOTE: Arquivos gerados em /usr/src/adm/logs/"
    color_title   "Título / Cabeçalho de seção"
    echo -e "${RESET}"
fi
