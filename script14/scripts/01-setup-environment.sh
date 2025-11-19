#!/usr/bin/env bash
#
# 01-setup-environment.sh
#
# Inicializa toda a estrutura do /usr/src/adm
# - Cria diretórios base
# - Valida ferramentas mínimas
# - Garante que NÃO existam erros silenciosos
# - Prepara logging global com cores, spinner e ✔/✖
# - Gera meta/hardware.info
# - Gera meta/global-env.sh
# - Gera ID de build e log dedicado
#

set -euo pipefail

###############################################################################
# CORES PADRÃO E LOGGING
###############################################################################

C_RESET="\033[0m"
C_INFO="\033[1;37m"
C_WARN="\033[1;33m"
C_ERR="\033[1;31m"
C_OK="\033[1;32m"
C_TASK="\033[1;36m"
C_BUILD="\033[1;33m"

SPINNER_PID=""
BUILD_ID=""
ADM_ROOT="/usr/src/adm"
LOG_FILE=""

timestamp() {
    date +"%H:%M:%S"
}

log_raw() {
    # log na tela + no arquivo (se definido)
    local line="$*"
    echo -e "$line"
    if [[ -n "${LOG_FILE:-}" ]]; then
        # remover cores pro arquivo
        echo -e "$(sed -r 's/\x1B\[[0-9;]*[mK]//g' <<< "$line")" >> "$LOG_FILE"
    fi
}

log_info() {
    log_raw "$(timestamp)  ${C_INFO}[INFO]${C_RESET} $*"
}

log_warn() {
    log_raw "$(timestamp)  ${C_WARN}[WARN]${C_RESET} $*"
}

log_error() {
    log_raw "$(timestamp)  ${C_ERR}[ERROR]${C_RESET} $*"
}

task_start() {
    local msg="$*"
    # imprime tag e mensagem, spinner entra no fim da linha
    echo -ne "$(timestamp)  ${C_BUILD}[TASK]${C_RESET} $msg "
    [[ -n "${LOG_FILE:-}" ]] && \
        echo "$(timestamp)  [TASK] $msg (START)" >> "$LOG_FILE"
    _start_spinner
}

task_ok() {
    _stop_spinner
    log_raw "${C_OK}✔${C_RESET}"
    [[ -n "${LOG_FILE:-}" ]] && \
        echo "$(timestamp)  [TASK] OK" >> "$LOG_FILE"
}

task_fail() {
    _stop_spinner
    log_raw "${C_ERR}✖${C_RESET}"
    [[ -n "${LOG_FILE:-}" ]] && \
        echo "$(timestamp)  [TASK] FAIL" >> "$LOG_FILE"
}

_start_spinner() {
    local spin='|/-\'
    (
        while true; do
            for i in $spin; do
                echo -ne "\b$i"
                sleep 0.1
            done
        done
    ) &
    SPINNER_PID=$!
}

_stop_spinner() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" >/dev/null 2>&1 || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        echo -ne "\b"
    fi
}

cleanup_on_exit() {
    local exit_code=$?
    _stop_spinner
    if [[ $exit_code -ne 0 ]]; then
        log_error "01-setup-environment.sh terminou com erro (código $exit_code)."
    fi
}
trap cleanup_on_exit EXIT INT TERM

###############################################################################
# VARIÁVEIS GERAIS DO AMBIENTE
###############################################################################

ADM_DIRS=(
    "repo"
    "repo/base"
    "repo/develop"
    "repo/libs"
    "repo/apps"
    "scripts"
    "sources"
    "build"
    "cache"
    "logs"
    "meta"
    "intelligence"
    "profiles"
)

REQUIRED_TOOLS=(
    bash
    awk
    sed
    tar
    xz
    gzip
    curl
    wget
    sha256sum
    md5sum
    make
)

###############################################################################
# FUNÇÕES PRINCIPAIS
###############################################################################

ensure_root_or_sudo() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "Este script precisa ser executado como root."
        exit 1
    fi
}

generate_build_id() {
    # ID de build simples, único o suficiente para log/identificação
    BUILD_ID="$(date +%Y%m%d-%H%M%S)-$$"
}

prepare_log_file() {
    mkdir -p "${ADM_ROOT}/logs" || {
        log_error "Falha ao criar diretório de logs: ${ADM_ROOT}/logs"
        exit 1
    }
    LOG_FILE="${ADM_ROOT}/logs/setup-${BUILD_ID}.log"
    touch "$LOG_FILE" || {
        log_error "Não foi possível criar log em $LOG_FILE"
        exit 1
    }
    log_info "Log principal deste setup: $LOG_FILE"
}

check_existing_structure() {
    # Se o diretório já existe, checa se é mesmo /usr/src/adm "normal"
    if [[ -d "$ADM_ROOT" ]]; then
        # Se meta/hardware.info já existe, avisa que é uma reexecução
        if [[ -f "${ADM_ROOT}/meta/hardware.info" ]]; then
            log_warn "Estrutura existente detectada em ${ADM_ROOT}. Setup será verificado, não recriado do zero."
        fi
    fi
}

create_directories() {
    task_start "Criando diretórios essenciais em ${ADM_ROOT}"
    mkdir -p "${ADM_ROOT}" || {
        task_fail
        log_error "Falha ao criar diretório raiz: ${ADM_ROOT}"
        exit 1
    }

    for d in "${ADM_DIRS[@]}"; do
        if [[ ! -d "${ADM_ROOT}/${d}" ]]; then
            mkdir -p "${ADM_ROOT}/${d}" || {
                task_fail
                log_error "Falha ao criar diretório: ${ADM_ROOT}/${d}"
                exit 1
            }
        fi
    done
    task_ok
}

validate_permissions() {
    task_start "Verificando permissões de escrita em ${ADM_ROOT}"
    if [[ ! -w "$ADM_ROOT" ]]; then
        task_fail
        log_error "Sem permissão de escrita em ${ADM_ROOT}. Ajuste permissões e tente novamente."
        exit 1
    fi

    # Testa escrita em meta/
    if ! touch "${ADM_ROOT}/meta/.perm_test" 2>/dev/null; then
        task_fail
        log_error "Falha ao escrever em ${ADM_ROOT}/meta. Verifique permissões."
        exit 1
    fi
    rm -f "${ADM_ROOT}/meta/.perm_test" || true
    task_ok
}

validate_tools() {
    task_start "Validando ferramentas essenciais do host"
    local missing=0

    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_error "Ferramenta ausente: $tool"
            missing=1
        fi
    done

    if [[ $missing -ne 0 ]]; then
        task_fail
        log_error "Uma ou mais ferramentas essenciais estão ausentes. Instale-as e rode o setup novamente."
        exit 1
    fi

    task_ok
}

generate_hardware_info() {
    task_start "Gerando meta/hardware.info"

    {
        echo "cpu: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //')"
        echo "cores: $(nproc 2>/dev/null || echo 1)"
        echo "arch: $(uname -m 2>/dev/null || echo unknown)"
        echo "memory_total_kb: $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')"
        echo "kernel: $(uname -r 2>/dev/null || echo unknown)"
        echo "os: $(uname -s 2>/dev/null || echo unknown)"
    } > "${ADM_ROOT}/meta/hardware.info" || {
        task_fail
        log_error "Falha ao escrever ${ADM_ROOT}/meta/hardware.info"
        exit 1
    }

    task_ok
}

prepare_global_env_file() {
    task_start "Criando meta/global-env.sh"

    cat > "${ADM_ROOT}/meta/global-env.sh" << 'EOF'
# meta/global-env.sh
# Arquivo de ambiente global para o ecossistema /usr/src/adm
# Este arquivo será lido por environment-wrapper.sh e demais scripts.

export ADM_ROOT="/usr/src/adm"

# PATH base incluirá toolchain (quando existir) e scripts
if [ -d "${ADM_ROOT}/toolchain/bin" ]; then
    export PATH="${ADM_ROOT}/toolchain/bin:${ADM_ROOT}/scripts:${PATH}"
else
    export PATH="${ADM_ROOT}/scripts:${PATH}"
fi

# Número padrão de jobs de compilação
if command -v nproc >/dev/null 2>&1; then
    export MAKEFLAGS="-j$(nproc)"
else
    export MAKEFLAGS="-j2"
fi

EOF

    task_ok
}

initialize_intelligence_db() {
    task_start "Inicializando estrutura mínima de inteligência"

    local dbdir="${ADM_ROOT}/intelligence"
    mkdir -p "$dbdir" || {
        task_fail
        log_error "Não foi possível criar diretório de inteligência: $dbdir"
        exit 1
    }

    # Para início, um arquivo texto simples; no futuro pode ser SQLite/etc.
    local info="${dbdir}/README.intelligence"
    if [[ ! -f "$info" ]]; then
        cat > "$info" << EOF
Este diretório armazena dados de inteligência do sistema de build:
- histórico de builds
- heurísticas
- dependências inferidas
- tempos e flags testadas

Formato inicial: arquivos de texto simples.
Pode ser migrado para banco mais avançado no futuro.
EOF
    fi

    task_ok
}

verify_structure_integrity() {
    task_start "Verificando integridade básica da estrutura /usr/src/adm"

    local expected=(
        "repo"
        "scripts"
        "sources"
        "build"
        "cache"
        "logs"
        "meta"
        "intelligence"
        "profiles"
    )

    local missing_any=0
    for d in "${expected[@]}"; do
        if [[ ! -d "${ADM_ROOT}/${d}" ]]; then
            log_error "Diretório esperado está faltando: ${ADM_ROOT}/${d}"
            missing_any=1
        fi
    done

    if [[ $missing_any -ne 0 ]]; then
        task_fail
        log_error "Estrutura de /usr/src/adm incompleta. Verifique se há algum problema de disco/permissão."
        exit 1
    fi

    task_ok
}

###############################################################################
# EXECUÇÃO PRINCIPAL
###############################################################################

main() {
    generate_build_id
    check_existing_structure
    prepare_log_file

    log_info "Iniciando 01-setup-environment.sh (BUILD_ID=${BUILD_ID})"
    log_info "Root de administração: ${ADM_ROOT}"

    ensure_root_or_sudo
    create_directories
    validate_permissions
    validate_tools
    generate_hardware_info
    prepare_global_env_file
    initialize_intelligence_db
    verify_structure_integrity

    log_info "${C_OK}Ambiente inicializado com sucesso.${C_RESET}"
}

main "$@"
