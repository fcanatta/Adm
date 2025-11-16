#!/usr/bin/env bash
# ui.sh - Interface de logs e spinner para o sistema adm
#
# Este script deve ser "sourced" pelos outros scripts:
#   . /usr/src/adm/scripts/ui.sh
#
# Responsabilidades:
#   - Logs coloridos na tela e logs simples em arquivo
#   - Spinner durante comandos longos
#   - Nunca engolir erros silenciosamente (todos retornam status)
#
# NÃO use "set -e" aqui dentro para não interferir com scripts chamadores.
# ==========================
# Variáveis globais
# ==========================
# Diretório de logs (pode ser sobrescrito antes de chamar adm_ui_init)
ADM_UI_LOG_DIR="${ADM_UI_LOG_DIR:-/usr/src/adm/logs}"

# Arquivo de log atual
ADM_UI_LOG_FILE=""

# Contexto corrente (fase/pacote)
ADM_UI_PHASE=""
ADM_UI_PACKAGE=""

# Controle de spinner
ADM_UI_SPINNER_PID=""
ADM_UI_SPINNER_ACTIVE=0

# Detectar se saída é terminal interativo
_adm_ui_is_tty() {
    [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]
}

# ==========================
# Cores ANSI (somente em TTY)
# ==========================

if _adm_ui_is_tty && [ -z "${ADM_NO_COLOR:-}" ]; then
    ADM_UI_COLOR_RESET=$'\033[0m'
    ADM_UI_COLOR_INFO=$'\033[1;34m'    # azul
    ADM_UI_COLOR_WARN=$'\033[1;33m'    # amarelo
    ADM_UI_COLOR_ERROR=$'\033[1;31m'   # vermelho
    ADM_UI_COLOR_OK=$'\033[1;32m'      # verde
else
    ADM_UI_COLOR_RESET=""
    ADM_UI_COLOR_INFO=""
    ADM_UI_COLOR_WARN=""
    ADM_UI_COLOR_ERROR=""
    ADM_UI_COLOR_OK=""
fi

# ==========================
# Funções internas
# ==========================

_adm_ui_timestamp() {
    # Formato: HH:MM:SS
    date +"%H:%M:%S"
}

_adm_ui_context() {
    local ctx=""
    if [ -n "$ADM_UI_PHASE" ]; then
        ctx+="[$ADM_UI_PHASE"
        if [ -n "$ADM_UI_PACKAGE" ]; then
            ctx+=":$ADM_UI_PACKAGE"
        fi
        ctx+="] "
    elif [ -n "$ADM_UI_PACKAGE" ]; then
        ctx+="[$ADM_UI_PACKAGE] "
    fi
    printf '%s' "$ctx"
}

_adm_ui_ensure_log_dir() {
    # Garante que o diretório de logs existe e é gravável
    if [ -z "$ADM_UI_LOG_DIR" ]; then
        echo "ui.sh: ADM_UI_LOG_DIR não definido" >&2
        return 1
    fi
    if ! mkdir -p "$ADM_UI_LOG_DIR" 2>/dev/null; then
        echo "ui.sh: não foi possível criar diretório de logs: $ADM_UI_LOG_DIR" >&2
        return 1
    fi
    if [ ! -w "$ADM_UI_LOG_DIR" ]; then
        echo "ui.sh: diretório de logs não é gravável: $ADM_UI_LOG_DIR" >&2
        return 1
    fi
    return 0
}

_adm_ui_write_logfile() {
    # $1 = nível, $2... = mensagem
    local level="$1"; shift || true
    local msg="$*"

    [ -z "$ADM_UI_LOG_FILE" ] && return 0  # se não tiver arquivo definido, só ignora

    # Garante diretório antes de gravar
    _adm_ui_ensure_log_dir || return 1

    printf '%s [%s] %s%s\n' "$(_adm_ui_timestamp)" "$level" "$(_adm_ui_context)" "$msg" >> "$ADM_UI_LOG_FILE"
}

_adm_ui_print_tty() {
    # $1 = nível, $2 = cor, $3... = msg
    local level="$1"; shift
    local color="$1"; shift
    local msg="$*"

    if _adm_ui_is_tty; then
        printf '%s %s[%s]%s %s%s\n' \
            "$(_adm_ui_timestamp)" \
            "$color" "$level" "$ADM_UI_COLOR_RESET" \
            "$(_adm_ui_context)" \
            "$msg"
    else
        # Sem cor quando não é TTY
        printf '%s [%s] %s%s\n' \
            "$(_adm_ui_timestamp)" \
            "$level" \
            "$(_adm_ui_context)" \
            "$msg"
    fi
}
# ==========================
# API pública: inicialização e contexto
# ==========================

adm_ui_init() {
    # Inicializa o sistema de UI.
    #   opcional: ADM_UI_LOG_DIR já definido externamente
    _adm_ui_ensure_log_dir || return 1
    return 0
}

adm_ui_set_log_file() {
    # Define o arquivo de log atual.
    # Uso:
    #   adm_ui_set_log_file fase pacote
    #
    # Se algum argumento estiver vazio, usa "generic".
    local phase="${1:-generic}"
    local pkg="${2:-generic}"

    _adm_ui_ensure_log_dir || return 1

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    ADM_UI_LOG_FILE="${ADM_UI_LOG_DIR}/${ts}-${phase}-${pkg}.log"

    # Tenta criar o arquivo cedo, para pegar erro já aqui
    if ! : > "$ADM_UI_LOG_FILE" 2>/dev/null; then
        echo "ui.sh: não foi possível criar arquivo de log: $ADM_UI_LOG_FILE" >&2
        ADM_UI_LOG_FILE=""
        return 1
    fi
    return 0
}

adm_ui_get_log_file() {
    # Imprime o caminho do log atual (pode ser vazio)
    printf '%s\n' "${ADM_UI_LOG_FILE:-}"
}

adm_ui_set_context() {
    # Define contexto exibido nas mensagens: fase e/ou pacote.
    # Uso:
    #   adm_ui_set_context fase pacote
    ADM_UI_PHASE="${1:-}"
    ADM_UI_PACKAGE="${2:-}"
}

# ==========================
# API pública: logs
# ==========================

adm_ui_log_info() {
    local msg="$*"
    _adm_ui_print_tty "INFO" "$ADM_UI_COLOR_INFO" "$msg"
    _adm_ui_write_logfile "INFO" "$msg"
}

adm_ui_log_warn() {
    local msg="$*"
    _adm_ui_print_tty "WARN" "$ADM_UI_COLOR_WARN" "$msg"
    _adm_ui_write_logfile "WARN" "$msg"
}

adm_ui_log_error() {
    local msg="$*"
    _adm_ui_print_tty "ERROR" "$ADM_UI_COLOR_ERROR" "$msg"
    _adm_ui_write_logfile "ERROR" "$msg"
}

adm_ui_log_ok() {
    local msg="$*"
    # usa ✔️ na mensagem
    msg="✔️  $msg"
    _adm_ui_print_tty "OK" "$ADM_UI_COLOR_OK" "$msg"
    _adm_ui_write_logfile "OK" "$msg"
}

adm_ui_log_raw() {
    # Escreve texto bruto apenas no log (sem prefixo de nível) – útil para despejar
    # saídas de comandos via tee ou assim.
    local msg="$*"
    [ -z "$ADM_UI_LOG_FILE" ] && return 0
    _adm_ui_ensure_log_dir || return 1
    printf '%s\n' "$msg" >> "$ADM_UI_LOG_FILE"
}

adm_ui_die() {
    # Sai do script chamador com erro, registrando a mensagem.
    # Uso:
    #   adm_ui_die "mensagem de erro"
    #   adm_ui_die 2 "mensagem de erro"
    local code=1
    local msg=""

    if [[ "$1" =~ ^[0-9]+$ ]]; then
        code="$1"
        shift || true
    fi
    msg="${*:-erro desconhecido}"

    adm_ui_log_error "$msg"

    if [ -n "$ADM_UI_LOG_FILE" ]; then
        printf 'Log detalhado em: %s\n' "$ADM_UI_LOG_FILE" >&2
    fi

    exit "$code"
}
# ==========================
# Spinner interno
# ==========================

_adm_ui_spinner_loop() {
    # $1 = mensagem
    # $2 = pid do comando
    local msg="$1"
    local cmd_pid="$2"

    # Não roda spinner se:
    #   - não for TTY
    #   - ADM_UI_SPINNER_ACTIVE já em uso
    if ! _adm_ui_is_tty || [ "$ADM_UI_SPINNER_ACTIVE" -ne 0 ]; then
        return 0
    fi

    ADM_UI_SPINNER_ACTIVE=1

    local frames=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    local i=0

    # Salva configuração de trap anterior para restaurar depois
    local old_trap
    old_trap="$(trap -p INT TERM 2>/dev/null || true)"

    # Enquanto o processo existir, atualiza o spinner
    while kill -0 "$cmd_pid" 2>/dev/null; do
        local frame="${frames[$((i % ${#frames[@]}))]}"
        printf '\r%s %s%s%s %s%s' \
            "$(_adm_ui_timestamp)" \
            "$ADM_UI_COLOR_INFO" "$frame" "$ADM_UI_COLOR_RESET" \
            "$(_adm_ui_context)" \
            "$msg"
        i=$((i + 1))
        sleep 0.1
    done

    # Limpa linha
    printf '\r\033[K'  # apaga a linha atual

    ADM_UI_SPINNER_ACTIVE=0

    # Restaura trap anterior (se existir)
    if [ -n "$old_trap" ]; then
        eval "$old_trap"
    else
        trap - INT TERM
    fi
}

# ==========================
# API pública: executar comandos com spinner
# ==========================

adm_ui_with_spinner() {
    # Executa um comando com spinner e log:
    #
    # Uso:
    #   adm_ui_with_spinner "Mensagem amigável" comando arg1 arg2 ...
    #
    # Comportamento:
    #   - Mensagem + spinner na tela enquanto o comando roda
    #   - stdout/stderr do comando vão para o log atual (ADM_UI_LOG_FILE)
    #   - No final, imprime ✔️ ou erro com código de retorno
    #
    # Retorna o mesmo código de saída do comando.

    if [ "$#" -lt 2 ]; then
        echo "uso: adm_ui_with_spinner \"mensagem\" comando [args...]" >&2
        return 2
    fi

    local msg="$1"; shift
    local cmd=("$@")

    # Garante que temos um arquivo de log configurado
    if [ -z "$ADM_UI_LOG_FILE" ]; then
        # Tenta criar um genérico
        adm_ui_set_log_file "generic" "generic" || {
            echo "ui.sh: ADM_UI_LOG_FILE não definido e não foi possível criar um genérico" >&2
            return 1
        }
    fi

    _adm_ui_ensure_log_dir || return 1

    # Loga início
    _adm_ui_write_logfile "INFO" "Iniciando: $msg (comando: ${cmd[*]})"

    # Executa comando em background, redirecionando stdout+stderr para o log
    "${cmd[@]}" >>"$ADM_UI_LOG_FILE" 2>&1 &
    local cmd_pid=$!

    # Erro já na criação do processo
    if ! kill -0 "$cmd_pid" 2>/dev/null; then
        adm_ui_log_error "Falha ao iniciar comando: ${cmd[*]}"
        return 1
    fi

    # Spinner (só se TTY)
    _adm_ui_spinner_loop "$msg" "$cmd_pid" &

    ADM_UI_SPINNER_PID=$!
    # Espera comando terminar
    wait "$cmd_pid"
    local rc=$?

    # Garante que o spinner loop terminará
    if kill -0 "$ADM_UI_SPINNER_PID" 2>/dev/null; then
        kill "$ADM_UI_SPINNER_PID" 2>/dev/null || true
        wait "$ADM_UI_SPINNER_PID" 2>/dev/null || true
    fi
    ADM_UI_SPINNER_PID=""

    if [ "$rc" -eq 0 ]; then
        adm_ui_log_ok "$msg"
        _adm_ui_write_logfile "INFO" "Concluído com sucesso: $msg"
    else
        adm_ui_log_error "$msg (falhou com código $rc)"
        _adm_ui_write_logfile "ERROR" "Falha: $msg (código $rc)"
    fi

    return "$rc"
}

# ==========================
# Execução direta (debug manual)
# ==========================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Se chamado diretamente, faz um pequeno teste interativo.
    adm_ui_init || exit 1
    adm_ui_set_context "test" "ui.sh"
    adm_ui_set_log_file "test" "ui-sh" || exit 1

    adm_ui_log_info "Teste de log INFO"
    adm_ui_log_warn "Teste de log WARN"
    adm_ui_log_error "Teste de log ERROR"
    adm_ui_log_ok "Teste de log OK"

    adm_ui_with_spinner "Dormindo 2 segundos" sleep 2

    echo "Log em: $(adm_ui_get_log_file)"
fi
