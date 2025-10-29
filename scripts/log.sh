#!/bin/bash
#===============================================================
#  ADM BUILD SYSTEM - log.sh
#  Sistema centralizado de logs e execução silenciosa
#===============================================================
#---------------------------------------------------------------
# Diretórios e variáveis essenciais
#---------------------------------------------------------------
ADM_ROOT="/usr/src/adm"
ADM_LOGS="$ADM_ROOT/logs"
mkdir -p "$ADM_LOGS" 2>/dev/null || {
    echo "Erro: não foi possível criar diretório de logs: $ADM_LOGS" >&2
    exit 1
}

#---------------------------------------------------------------
# Variáveis de ambiente
#---------------------------------------------------------------
ADM_LOGFILE=""
ADM_PKG_NAME="${ADM_PKG_NAME:-unknown}"
BUILD_ID=$(date +%Y-%m-%d_%H-%M-%S)

#---------------------------------------------------------------
# Cores (para terminal)
#---------------------------------------------------------------
C_RESET="\033[0m"
C_BLUE="\033[1;34m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_GRAY="\033[0;37m"

#---------------------------------------------------------------
# Função interna: timestamp formatado
#---------------------------------------------------------------
log_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

#---------------------------------------------------------------
# Inicializa sessão de log
#---------------------------------------------------------------
log_init() {
    local context="${1:-session}"
    ADM_LOGFILE="$ADM_LOGS/${BUILD_ID}_${context}.log"

    {
        echo "============================================================"
        echo " ADM BUILD SYSTEM - LOG SESSION"
        echo " Contexto : $context"
        echo " Início   : $(log_timestamp)"
        echo "============================================================"
        echo
    } >> "$ADM_LOGFILE"

    export ADM_LOGFILE
    return 0
}

#---------------------------------------------------------------
# Fecha sessão de log
#---------------------------------------------------------------
log_close() {
    {
        echo
        echo "============================================================"
        echo " Fim da sessão : $(log_timestamp)"
        echo "============================================================"
        echo
    } >> "$ADM_LOGFILE"
}

#---------------------------------------------------------------
# Registra mensagem informativa
#---------------------------------------------------------------
log_info() {
    local msg="$*"
    echo "[$(log_timestamp)] [INFO] $msg" >> "$ADM_LOGFILE"
}

#---------------------------------------------------------------
# Registra aviso
#---------------------------------------------------------------
log_warn() {
    local msg="$*"
    echo -e "${C_YELLOW}[WARN]${C_RESET} $msg"
    echo "[$(log_timestamp)] [WARN] $msg" >> "$ADM_LOGFILE"
}

#---------------------------------------------------------------
# Registra erro
#---------------------------------------------------------------
log_error() {
    local msg="$*"
    echo -e "${C_RED}[ERROR]${C_RESET} $msg" >&2
    echo "[$(log_timestamp)] [ERROR] $msg" >> "$ADM_LOGFILE"
}

#---------------------------------------------------------------
# Executa comandos silenciosamente e registra saída
#---------------------------------------------------------------
log_exec() {
    local cmd="$*"
    local start=$(date +%s)
    echo "[CMD] $cmd" >> "$ADM_LOGFILE"

    eval "$cmd" >>"$ADM_LOGFILE" 2>&1
    local status=$?

    local end=$(date +%s)
    local elapsed=$((end - start))
    local m=$((elapsed / 60))
    local s=$((elapsed % 60))
    local duration=$(printf "%02dm%02ds" "$m" "$s")

    if [ $status -eq 0 ]; then
        echo "[OK] Comando concluído em $duration" >> "$ADM_LOGFILE"
        echo -e "${C_GREEN}✔${C_RESET} $cmd (${C_GRAY}${duration}${C_RESET})"
    else
        echo "[FAIL] Código $status após $duration" >> "$ADM_LOGFILE"
        echo -e "${C_RED}✖${C_RESET} $cmd (${C_GRAY}${duration}${C_RESET})"
    fi

    return $status
}

#---------------------------------------------------------------
# Seção de log (com nome do pacote e diretório atual)
#---------------------------------------------------------------
log_section() {
    local section="$*"
    local dir="$(pwd)"
    local pkg="${ADM_PKG_NAME:-unknown}"

    echo -e "\n${C_BLUE}------------------------------------------------------------${C_RESET}"
    echo -e "${C_GREEN}[SECTION]${C_RESET} ${C_YELLOW}${section}${C_RESET}"
    echo -e "${C_GRAY} Pacote   : ${pkg}${C_RESET}"
    echo -e "${C_GRAY} Diretório: ${dir}${C_RESET}"
    echo -e "${C_BLUE}------------------------------------------------------------${C_RESET}\n"

    {
        echo "------------------------------------------------------------"
        echo " [SECTION] $section"
        echo " Pacote   : $pkg"
        echo " Diretório: $dir"
        echo "------------------------------------------------------------"
    } >> "$ADM_LOGFILE"
}

#---------------------------------------------------------------
# Rotação automática de logs (mantém últimos 20)
#---------------------------------------------------------------
log_rotate() {
    local max=20
    cd "$ADM_LOGS" || return 0
    local count
    count=$(ls -1t *.log 2>/dev/null | wc -l)
    if [ "$count" -gt "$max" ]; then
        ls -1t *.log | tail -n +$((max + 1)) | while read -r oldlog; do
            gzip -f "$oldlog" 2>/dev/null
        done
    fi
}

#---------------------------------------------------------------
# Execução de segurança
#---------------------------------------------------------------
trap 'log_close' EXIT
