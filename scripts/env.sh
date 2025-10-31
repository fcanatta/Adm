#!/usr/bin/env bash
#=============================================================
#  env.sh — Configuração e inicialização do ambiente ADM Build
#-------------------------------------------------------------
#  Responsável por:
#   - Carregar módulos base (colors.sh e log.sh)
#   - Definir e exportar variáveis de ambiente
#   - Garantir estrutura de diretórios
#   - Validar dependências e permissões
#   - Carregar perfil ativo de compilação
#
#  Uso:
#     source /usr/src/adm/scripts/env.sh
#
#  Teste rápido:
#     bash /usr/src/adm/scripts/env.sh --test
#=============================================================
#-------------------------------------------------------------
#  Proteção contra múltiplas inclusões
#-------------------------------------------------------------
[[ -n "${ADM_ENV_SH_LOADED}" ]] && return
ADM_ENV_SH_LOADED=1

#-------------------------------------------------------------
#  Impedir execução direta
#-------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "❌ Este script não deve ser executado diretamente."
    echo "   Use: source /usr/src/adm/scripts/env.sh"
    exit 1
fi

#-------------------------------------------------------------
#  Carregar módulos base
#-------------------------------------------------------------
source /usr/src/adm/scripts/colors.sh
source /usr/src/adm/scripts/log.sh

#-------------------------------------------------------------
#  Definir diretórios principais
#-------------------------------------------------------------
ADM_ROOT="/usr/src/adm"
ADM_SCRIPTS_DIR="${ADM_ROOT}/scripts"
ADM_REPO_DIR="${ADM_ROOT}/repo"
ADM_BUILD_DIR="${ADM_ROOT}/build"
ADM_LOG_DIR="${ADM_ROOT}/logs"
ADM_BOOTSTRAP_DIR="${ADM_ROOT}/bootstrap"
ADM_CACHE_DIR="${ADM_ROOT}/cache"
ADM_CACHE_SOURCES="${ADM_CACHE_DIR}/sources"
ADM_CACHE_PACKAGES="${ADM_CACHE_DIR}/packages"
ADM_CONFIG_DIR="${ADM_ROOT}/config"
ADM_UPDATE_DIR="${ADM_ROOT}/update"
ADM_PROFILE_DIR="${ADM_CONFIG_DIR}/profiles"

#-------------------------------------------------------------
#  Criar diretórios automaticamente, se faltarem
#-------------------------------------------------------------
ensure_dir() {
    [[ -d "$1" ]] || { mkdir -p "$1" && log_info "Criado diretório: $1"; }
}

for dir in \
    "$ADM_REPO_DIR" "$ADM_BUILD_DIR" "$ADM_LOG_DIR" \
    "$ADM_BOOTSTRAP_DIR" "$ADM_CACHE_SOURCES" "$ADM_CACHE_PACKAGES" \
    "$ADM_CONFIG_DIR" "$ADM_UPDATE_DIR"; do
    ensure_dir "$dir"
done

#-------------------------------------------------------------
#  Verificação de permissões
#-------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    log_warn "Executando sem privilégios de root — algumas operações podem falhar."
fi

#-------------------------------------------------------------
#  Verificação de dependências do sistema
#-------------------------------------------------------------
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log_error "Comando obrigatório não encontrado: $1"
        MISSING_DEPS=true
    }
}

log_section "Verificando dependências básicas"
MISSING_DEPS=false
for cmd in bash wget tar make gcc sha256sum tee; do
    require_cmd "$cmd"
done

if $MISSING_DEPS; then
    log_error "Uma ou mais dependências estão ausentes. Corrija antes de continuar."
    exit 1
else
    log_success "Todas as dependências básicas estão disponíveis."
fi

#-------------------------------------------------------------
#  Carregar perfil ativo
#-------------------------------------------------------------
ADM_PROFILE="${ADM_PROFILE:-default}"

if [[ -f "${ADM_PROFILE_DIR}/${ADM_PROFILE}.conf" ]]; then
    source "${ADM_PROFILE_DIR}/${ADM_PROFILE}.conf"
    log_info "Perfil de build carregado: ${ADM_PROFILE}"
else
    log_warn "Perfil '${ADM_PROFILE}' não encontrado. Usando configuração padrão."
fi

#-------------------------------------------------------------
#  Exportar variáveis de ambiente
#-------------------------------------------------------------
export ADM_ROOT ADM_SCRIPTS_DIR ADM_REPO_DIR ADM_BUILD_DIR ADM_LOG_DIR
export ADM_BOOTSTRAP_DIR ADM_CACHE_DIR ADM_CACHE_SOURCES ADM_CACHE_PACKAGES
export ADM_CONFIG_DIR ADM_UPDATE_DIR ADM_PROFILE_DIR ADM_PROFILE

#-------------------------------------------------------------
#  Funções auxiliares
#-------------------------------------------------------------
show_env_summary() {
    echo -e "\n${BOLD}${BRIGHT_BLUE}=== RESUMO DO AMBIENTE ADM BUILD ===${RESET}"
    echo -e "${BOLD}Root:${RESET}            ${ADM_ROOT}"
    echo -e "${BOLD}Scripts:${RESET}         ${ADM_SCRIPTS_DIR}"
    echo -e "${BOLD}Repositório:${RESET}     ${ADM_REPO_DIR}"
    echo -e "${BOLD}Build:${RESET}           ${ADM_BUILD_DIR}"
    echo -e "${BOLD}Cache (sources):${RESET} ${ADM_CACHE_SOURCES}"
    echo -e "${BOLD}Cache (packages):${RESET}${ADM_CACHE_PACKAGES}"
    echo -e "${BOLD}Logs:${RESET}            ${ADM_LOG_DIR}"
    echo -e "${BOLD}Bootstrap:${RESET}       ${ADM_BOOTSTRAP_DIR}"
    echo -e "${BOLD}Perfil ativo:${RESET}    ${ADM_PROFILE}\n"
}

reset_env() {
    log_info "Recarregando ambiente ADM..."
    source /usr/src/adm/scripts/env.sh
}

#-------------------------------------------------------------
#  Função de teste
#-------------------------------------------------------------
if [[ "${1}" == "--test" ]]; then
    echo -e "\n${BOLD}${BRIGHT_BLUE}=== Teste do ambiente ADM Build System ===${RESET}\n"
    log_init
    log_section "Iniciando verificação de ambiente"
    log_info "Verificando estrutura de diretórios..."
    for d in "$ADM_REPO_DIR" "$ADM_CACHE_DIR" "$ADM_BUILD_DIR" "$ADM_LOG_DIR"; do
        [[ -d "$d" ]] && log_success "✔ Diretório OK: $d" || log_error "❌ Faltando: $d"
    done
    log_info "Verificando dependências básicas..."
    for cmd in bash wget tar make gcc sha256sum tee; do
        command -v "$cmd" >/dev/null && log_success "✔ $cmd encontrado" || log_error "❌ $cmd ausente"
    done
    show_env_summary
    log_success "Ambiente carregado com sucesso!"
    log_close
fi
