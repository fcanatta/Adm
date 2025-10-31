#!/usr/bin/env bash
#=============================================================
#  utils.sh — Biblioteca de utilitários do ADM Build System
#-------------------------------------------------------------
#  Fornece funções auxiliares reutilizáveis para:
#   - verificações de ambiente e rede
#   - manipulação de arquivos e diretórios
#   - formatação de tempo, tamanhos e nomes
#   - controle de erros e retentativas
#
#  Uso:
#     source /usr/src/adm/scripts/utils.sh
#     bash utils.sh --test   # modo de demonstração
#=============================================================

[[ -n "${ADM_UTILS_SH_LOADED}" ]] && return
ADM_UTILS_SH_LOADED=1

#-------------------------------------------------------------
#  Segurança: impedir execução direta
#-------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "❌ Este script não deve ser executado diretamente."
    echo "   Use: source /usr/src/adm/scripts/utils.sh"
    exit 1
fi

#-------------------------------------------------------------
#  Dependências
#-------------------------------------------------------------
source /usr/src/adm/scripts/colors.sh
source /usr/src/adm/scripts/log.sh
source /usr/src/adm/scripts/env.sh

#-------------------------------------------------------------
#  🔍 Funções de verificação
#-------------------------------------------------------------

check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Comando não encontrado: ${cmd}"
        return 1
    fi
    return 0
}

ensure_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || { mkdir -p "$dir" && log_info "Criado diretório: $dir"; }
}

check_permission() {
    local dir="$1"
    if [[ ! -w "$dir" ]]; then
        log_warn "Sem permissão de escrita em: ${dir}"
        return 1
    fi
}

check_internet() {
    if ! ping -c1 -W1 8.8.8.8 &>/dev/null; then
        log_error "Sem conexão com a Internet."
        return 1
    fi
    log_success "Conexão com a Internet detectada."
}

#-------------------------------------------------------------
#  🧰 Funções de manipulação de arquivos
#-------------------------------------------------------------

safe_copy() {
    local src="$1" dest="$2"
    if cp -r "$src" "$dest" 2>>"$ADM_LOG_FILE"; then
        log_info "Copiado: ${src} → ${dest}"
    else
        log_error "Falha ao copiar: ${src}"
        return 1
    fi
}

safe_remove() {
    local target="$1"
    if [[ -e "$target" ]]; then
        rm -rf "$target" && log_info "Removido: $target"
    fi
}

verify_checksum() {
    local file="$1" checksum="$2"
    local calc
    calc=$(sha256sum "$file" | awk '{print $1}')
    if [[ "$calc" != "$checksum" ]]; then
        log_error "Checksum inválido para ${file}"
        return 1
    fi
    log_success "Checksum válido para ${file}"
}

#-------------------------------------------------------------
#  🕒 Funções de tempo e sistema
#-------------------------------------------------------------

start_timer() {
    ADM_TIMER_START=$(date +%s)
}

stop_timer() {
    local end=$(date +%s)
    echo $((end - ADM_TIMER_START))
}

format_time() {
    local sec="$1"
    printf "%02d:%02d:%02d" $((sec/3600)) $(((sec%3600)/60)) $((sec%60))
}

format_size() {
    local bytes=$1
    if ((bytes < 1024)); then
        echo "${bytes}B"
    elif ((bytes < 1048576)); then
        echo "$((bytes/1024))KB"
    elif ((bytes < 1073741824)); then
        echo "$((bytes/1048576))MB"
    else
        echo "$((bytes/1073741824))GB"
    fi
}

#-------------------------------------------------------------
#  ⚠️ Funções de controle de erro
#-------------------------------------------------------------

abort_build() {
    local msg="$1"
    log_error "Build abortado: ${msg}"
    echo -e "${RED}✖ ${msg}${RESET}"
    exit 1
}

retry() {
    local attempts="$1"; shift
    local cmd="$@"
    for ((i=1; i<=attempts; i++)); do
        eval "$cmd" && return 0
        log_warn "Tentativa ${i}/${attempts} falhou. Retentando..."
        sleep 2
    done
    log_error "Todas as ${attempts} tentativas falharam: ${cmd}"
    return 1
}

#-------------------------------------------------------------
#  🧩 Funções de formatação e strings
#-------------------------------------------------------------

normalize_pkgname() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]//g'
}

print_section() {
    echo -e "\n${BOLD}${BRIGHT_BLUE}=== $1 ===${RESET}"
    log_info "$1"
}

#-------------------------------------------------------------
#  🧪 Modo de teste
#-------------------------------------------------------------
if [[ "$1" == "--test" ]]; then
    log_init
    print_section "Teste do módulo utils.sh"

    ensure_dir "/tmp/adm-test"
    check_permission "/tmp/adm-test"
    check_command "bash"
    check_internet

    log_info "Copiando arquivo de teste..."
    safe_copy "/etc/hosts" "/tmp/adm-test/"

    log_info "Verificando checksum..."
    verify_checksum "/etc/hosts" "$(sha256sum /etc/hosts | awk '{print $1}')"

    log_info "Simulando operação com retentativas..."
    retry 3 "false"

    start_timer
    sleep 2
    local t=$(stop_timer)
    log_info "Tempo decorrido: $(format_time $t)"

    echo -e "\nTamanho formatado: $(format_size 10485760)"
    echo -e "Nome normalizado: $(normalize_pkgname 'GLIBC@2.39-dev')"

    log_close
fi
