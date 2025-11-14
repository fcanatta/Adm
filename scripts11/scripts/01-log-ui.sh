#!/usr/bin/env bash
# 01-log-ui.sh
# Camada de UI / Logging do ADM (ADM tools construction).
# ----------------------------------------------------------------------
# Requisitos e modo seguro
# ----------------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 01-log-ui.sh requer bash." >&2
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'
# ----------------------------------------------------------------------
# Metadados do ADM
# ----------------------------------------------------------------------
ADM_NAME="${ADM_NAME:-adm}"
ADM_VERSION="${ADM_VERSION:-1.0}"
ADM_TAGLINE="${ADM_TAGLINE:-ADM tools construction}"

ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"
ADM_LOG_DIR_DEFAULT="$ADM_ROOT/log"
ADM_LOG_DIR="${ADM_LOG_DIR:-$ADM_LOG_DIR_DEFAULT}"
# ----------------------------------------------------------------------
# Detecção de suporte a cores / TTY
# ----------------------------------------------------------------------
ADM_COLOR_ENABLED=0

if [ -t 2 ]; then
    if command -v tput >/dev/null 2>&1; then
        if tput colors >/dev/null 2>&1; then
            ADM_COLOR_ENABLED=1
        fi
    fi
fi

if [ "$ADM_COLOR_ENABLED" -eq 1 ]; then
    ADM_CLR_RESET="$(printf '\033[0m')"
    ADM_CLR_DIM="$(printf '\033[2m')"
    ADM_CLR_BOLD="$(printf '\033[1m')"

    ADM_CLR_INFO="$(printf '\033[36m')"    # ciano
    ADM_CLR_WARN="$(printf '\033[33m')"    # amarelo
    ADM_CLR_ERROR="$(printf '\033[31m')"   # vermelho
    ADM_CLR_OK="$(printf '\033[32m')"      # verde
    ADM_CLR_HEADER="$(printf '\033[35m')"  # magenta
else
    ADM_CLR_RESET=""
    ADM_CLR_DIM=""
    ADM_CLR_BOLD=""
    ADM_CLR_INFO=""
    ADM_CLR_WARN=""
    ADM_CLR_ERROR=""
    ADM_CLR_OK=""
    ADM_CLR_HEADER=""
fi
# ----------------------------------------------------------------------
# Contexto de log global
# ----------------------------------------------------------------------
ADM_LOG_INITIALIZED=0
ADM_LOG_PATH="${ADM_LOG_PATH:-}"   # será definido em adm_log_init
# Contexto atual de “programa sendo construído”
ADM_CTX_NAME=""
ADM_CTX_VERSION=""
ADM_CTX_CATEGORY=""
ADM_CTX_DEPS=""
ADM_CTX_HOOKS=""
ADM_CTX_PATCHES=""
ADM_CTX_REPO_DIR=""
ADM_CTX_BUILD_DIR=""
ADM_CTX_BIN_DIR=""
ADM_CTX_LOG_PATH=""   # log específico daquele build, se existir
# Spinner
ADM_SPINNER_PID=""
ADM_SPINNER_MSG=""
# ----------------------------------------------------------------------
# Utilitários básicos
# ----------------------------------------------------------------------
adm_log_ts() {
    date +"%Y-%m-%d %H:%M:%S"
}

adm_ensure_dir() {
    local d="${1:-}"
    if [ -z "$d" ]; then
        printf 'ERRO: adm_ensure_dir chamado com caminho vazio\n' >&2
        exit 1
    fi
    if [ -d "$d" ]; then
        return 0
    fi
    if ! mkdir -p "$d"; then
        printf 'ERRO: Falha ao criar diretório: %s\n' "$d" >&2
        exit 1
    fi
}

# ----------------------------------------------------------------------
# Inicialização do log principal
# ----------------------------------------------------------------------

adm_log_init() {
    if [ "$ADM_LOG_INITIALIZED" -eq 1 ]; then
        return 0
    fi

    adm_ensure_dir "$ADM_LOG_DIR"

    if [ -z "${ADM_LOG_PATH:-}" ]; then
        local ts
        ts="$(date +"%Y%m%d-%H%M%S")"
        ADM_LOG_PATH="${ADM_LOG_DIR}/${ADM_NAME}-${ts}.log"
    fi

    # Tenta criar arquivo de log
    if ! touch "$ADM_LOG_PATH" 2>/dev/null; then
        # fallback para /tmp
        local ts
        ts="$(date +"%Y%m%d-%H%M%S")"
        ADM_LOG_PATH="/tmp/${ADM_NAME}-${ts}.log"
        if ! touch "$ADM_LOG_PATH" 2>/dev/null; then
            printf 'ERRO: Não foi possível criar arquivo de log em %s nem em /tmp.\n' "$ADM_LOG_DIR" >&2
            exit 1
        fi
    fi

    ADM_LOG_INITIALIZED=1

    # Escreve cabeçalho no log
    {
        printf '=== %s %s - %s ===\n' "$ADM_NAME" "$ADM_VERSION" "$ADM_TAGLINE"
        printf 'Log iniciado em: %s\n' "$(adm_log_ts)"
        printf 'Arquivo de log: %s\n' "$ADM_LOG_PATH"
        printf '\n'
    } >>"$ADM_LOG_PATH"
}

adm_log_set_file() {
    # Permite que algum script defina manualmente o caminho de log principal.
    local path="${1:-}"
    if [ -z "$path" ]; then
        printf 'ERRO: adm_log_set_file chamado com caminho vazio\n' >&2
        exit 1
    fi
    ADM_LOG_PATH="$path"
    ADM_LOG_INITIALIZED=0
    adm_log_init
}

# ----------------------------------------------------------------------
# Escrita de log (núcleo)
# ----------------------------------------------------------------------

_adm_log_write() {
    # $1: level (INFO/WARN/ERRO/OK/STAGE/etc.)
    # $2: ícone
    # $3: cor
    # $4...: mensagem
    local level="$1"; shift
    local icon="$1"; shift
    local color="$1"; shift
    local msg="$*"

    adm_log_init

    local ts ctx_pkg ctx_log

    ts="$(adm_log_ts)"

    if [ -n "$ADM_CTX_NAME" ]; then
        ctx_pkg="${ADM_CTX_NAME}-${ADM_CTX_VERSION}"
    else
        ctx_pkg="-"
    fi

    if [ -n "$ADM_CTX_LOG_PATH" ]; then
        ctx_log="$ADM_CTX_LOG_PATH"
    else
        ctx_log="$ADM_LOG_PATH"
    fi

    # Linha bonita na tela
    # Formato: [TS] [adm 1.0] [pkg] [LEVEL] mensagem
    printf '%s[%s] [%s %s] [%s] [%s] %s%s\n' \
        "$color" \
        "$ts" \
        "$ADM_NAME" "$ADM_VERSION" \
        "$ctx_pkg" \
        "$level" \
        "$icon " \
        "$msg${ADM_CLR_RESET}" \
        >&2

    # Linha sem cores no log
    printf '[%s] [%s %s] [%s] [%s] %s %s\n' \
        "$ts" \
        "$ADM_NAME" "$ADM_VERSION" \
        "$ctx_pkg" \
        "$level" \
        "$icon" \
        "$msg" \
        >>"$ADM_LOG_PATH"
}

# ----------------------------------------------------------------------
# Funções públicas de log de linha
# ----------------------------------------------------------------------

adm_info() {
    _adm_log_write "INFO" "ℹ️" "$ADM_CLR_INFO" "$*"
}

adm_warn() {
    _adm_log_write "WARN" "⚠️" "$ADM_CLR_WARN" "$*"
}

adm_error() {
    _adm_log_write "ERRO" "❌" "$ADM_CLR_ERROR" "$*"
}

adm_success() {
    _adm_log_write "OK" "✔️" "$ADM_CLR_OK" "$*"
}

adm_die() {
    adm_error "$*"
    exit 1
}

adm_stage() {
    # Para marcar grandes etapas do processo
    local msg="$*"
    local line="──────────────────────────────────────────────────────────────"
    adm_log_init
    printf '%s%s\n' "$ADM_CLR_HEADER" "$line" >&2
    _adm_log_write "STAGE" "🚧" "$ADM_CLR_HEADER" "$msg"
    printf '%s%s%s\n' "$ADM_CLR_HEADER" "$line" "$ADM_CLR_RESET" >&2
}

# ----------------------------------------------------------------------
# Contexto de programa / build
# ----------------------------------------------------------------------

adm_log_set_program_context() {
    # Define contexto do programa atual.
    # Argumentos (todos opcionais, mas ideal passar tudo):
    #   1: name
    #   2: version
    #   3: category
    #   4: deps (string)
    #   5: hooks (string)
    #   6: patches (string)
    #   7: repo_dir
    #   8: build_dir
    #   9: bin_dir
    #  10: log_path específico

    ADM_CTX_NAME="${1:-}"
    ADM_CTX_VERSION="${2:-}"
    ADM_CTX_CATEGORY="${3:-}"
    ADM_CTX_DEPS="${4:-}"
    ADM_CTX_HOOKS="${5:-}"
    ADM_CTX_PATCHES="${6:-}"
    ADM_CTX_REPO_DIR="${7:-}"
    ADM_CTX_BUILD_DIR="${8:-}"
    ADM_CTX_BIN_DIR="${9:-}"
    ADM_CTX_LOG_PATH="${10:-}"

    if [ -n "$ADM_CTX_LOG_PATH" ]; then
        # Garante existência do diretório de log específico
        local ctx_dir
        ctx_dir="$(dirname "$ADM_CTX_LOG_PATH")"
        adm_ensure_dir "$ctx_dir"
        # Cria arquivo, se possível
        touch "$ADM_CTX_LOG_PATH" 2>/dev/null || true
    fi
}

adm_log_program_header() {
    # Mostra um cabeçalho bonito com o contexto do programa atual.
    adm_log_init

    local line="══════════════════════════════════════════════════════════════"
    local name="${ADM_CTX_NAME:-<desconhecido>}"
    local ver="${ADM_CTX_VERSION:-<desconhecida>}"
    local cat="${ADM_CTX_CATEGORY:-<desconhecida>}"
    local deps="${ADM_CTX_DEPS:-<nenhuma>}"
    local hooks="${ADM_CTX_HOOKS:-<nenhum>}"
    local patches="${ADM_CTX_PATCHES:-<nenhum>}"
    local repo="${ADM_CTX_REPO_DIR:-<desconhecido>}"
    local build="${ADM_CTX_BUILD_DIR:-<desconhecido>}"
    local bin="${ADM_CTX_BIN_DIR:-<desconhecido>}"
    local logp

    if [ -n "$ADM_CTX_LOG_PATH" ]; then
        logp="$ADM_CTX_LOG_PATH"
    else
        logp="$ADM_LOG_PATH"
    fi

    # Tela
    printf '%s%s\n' "$ADM_CLR_HEADER" "$line" >&2
    printf '%s%s %s %s%s\n' \
        "$ADM_CLR_HEADER" \
        "$ADM_NAME" \
        "$ADM_VERSION" \
        " - $ADM_TAGLINE" \
        "$ADM_CLR_RESET" >&2
    printf '%sPrograma:%s %s\n' "$ADM_CLR_BOLD" "$ADM_CLR_RESET" "$name" >&2
    printf '%sVersão:%s   %s\n' "$ADM_CLR_BOLD" "$ADM_CLR_RESET" "$ver" >&2
    printf '%sCategoria:%s %s\n' "$ADM_CLR_BOLD" "$ADM_CLR_RESET" "$cat" >&2
    printf '%sDependências:%s %s\n' "$ADM_CLR_BOLD" "$ADM_CLR_RESET" "$deps" >&2
    printf '%sHooks:%s        %s\n' "$ADM_CLR_BOLD" "$ADM_CLR_RESET" "$hooks" >&2
    printf '%sPatches:%s      %s\n' "$ADM_CLR_BOLD" "$ADM_CLR_RESET" "$patches" >&2
    printf '%sRepo dir:%s     %s\n' "$ADM_CLR_BOLD" "$ADM_CLR_RESET" "$repo" >&2
    printf '%sBuild dir:%s    %s\n' "$ADM_CLR_BOLD" "$ADM_CLR_RESET" "$build" >&2
    printf '%sBinário dir:%s  %s\n' "$ADM_CLR_BOLD" "$ADM_CLR_RESET" "$bin" >&2
    printf '%sLog ativo:%s    %s\n' "$ADM_CLR_BOLD" "$ADM_CLR_RESET" "$logp" >&2
    printf '%s%s%s\n' "$ADM_CLR_HEADER" "$line" "$ADM_CLR_RESET" >&2

    # Log também recebe esse resumo (sem cores)
    {
        printf '=== Programa: %s (%s) ===\n' "$name" "$ver"
        printf 'Categoria: %s\n' "$cat"
        printf 'Dependências: %s\n' "$deps"
        printf 'Hooks: %s\n' "$hooks"
        printf 'Patches: %s\n' "$patches"
        printf 'Repo dir: %s\n' "$repo"
        printf 'Build dir: %s\n' "$build"
        printf 'Binário dir: %s\n' "$bin"
        printf 'Log ativo: %s\n' "$logp"
        printf '\n'
    } >>"$ADM_LOG_PATH"
}

adm_log_global_header() {
    # Cabeçalho global, bom para ser mostrado no início da execução do adm.
    adm_log_init
    local line="══════════════════════════════════════════════════════════════"
    printf '%s%s\n' "$ADM_CLR_HEADER" "$line" >&2
    printf '%s%s %s%s\n' "$ADM_CLR_HEADER" "$ADM_NAME" "$ADM_VERSION" "$ADM_CLR_RESET" >&2
    printf '%s%s%s\n' "$ADM_CLR_DIM" "$ADM_TAGLINE" "$ADM_CLR_RESET" >&2
    printf '%sLog principal:%s %s\n' "$ADM_CLR_BOLD" "$ADM_CLR_RESET" "$ADM_LOG_PATH" >&2
    printf '%s%s%s\n' "$ADM_CLR_HEADER" "$line" "$ADM_CLR_RESET" >&2
}

# ----------------------------------------------------------------------
# Spinner
# ----------------------------------------------------------------------

adm_spinner_start() {
    # Inicia um spinner com uma mensagem.
    local msg="${*:-Processando...}"
    # Se já tiver spinner ativo, pára
    if [ -n "${ADM_SPINNER_PID:-}" ]; then
        adm_spinner_stop "interrompido"
    fi

    ADM_SPINNER_MSG="$msg"

    # Se não for TTY, não mostrar spinner (evita sujeira em logs redirecionados)
    if [ "$ADM_COLOR_ENABLED" -eq 0 ] || [ ! -t 2 ]; then
        ADM_SPINNER_PID=""
        adm_info "$msg"
        return 0
    fi

    (
        # Subshell do spinner
        # frames simples
        local frames=('-' '\' '|' '/')
        local i=0
        local c
        while :; do
            c="${frames[$((i % 4))]}"
            i=$((i + 1))
            printf '\r%s[%s %s]%s %s %s' \
                "$ADM_CLR_DIM" "$ADM_NAME" "$ADM_VERSION" "$ADM_CLR_RESET" \
                "$c" \
                "$ADM_SPINNER_MSG" \
                >&2
            sleep 0.1
        done
    ) &
    ADM_SPINNER_PID=$!
}

adm_spinner_stop() {
    # $1: status opcional (ex.: "ok", "erro")
    local status="${1:-}"

    if [ -z "${ADM_SPINNER_PID:-}" ]; then
        return 0
    fi

    # Tenta matar o spinner
    if kill "$ADM_SPINNER_PID" 2>/dev/null; then
        wait "$ADM_SPINNER_PID" 2>/dev/null || true
    fi
    ADM_SPINNER_PID=""

    # Limpa a linha do spinner
    if [ -t 2 ]; then
        printf '\r\033[K' >&2
    fi

    if [ -n "$status" ]; then
        case "$status" in
            ok|OK|success)
                adm_success "$ADM_SPINNER_MSG"
                ;;
            erro|error|fail|failed)
                adm_error "$ADM_SPINNER_MSG"
                ;;
            *)
                adm_info "$ADM_SPINNER_MSG"
                ;;
        esac
    fi

    ADM_SPINNER_MSG=""
}

# ----------------------------------------------------------------------
# Execução com spinner
# ----------------------------------------------------------------------

adm_run_with_spinner() {
    # Uso:
    #   adm_run_with_spinner "Mensagem bonita" comando arg1 arg2 ...
    #
    # Faz:
    #   - inicia spinner com a mensagem
    #   - executa o comando
    #   - para o spinner com ✔️ se sucesso ou ❌ se erro
    #   - retorna o código de saída do comando
    if [ "$#" -lt 2 ]; then
        adm_die "adm_run_with_spinner requer pelo menos 2 argumentos: mensagem e comando"
    fi

    local msg="$1"; shift

    adm_spinner_start "$msg"
    # Executa comando
    local rc=0
    if "$@"; then
        rc=0
    else
        rc=$?
    fi

    if [ $rc -eq 0 ]; then
        adm_spinner_stop "ok"
    else
        adm_spinner_stop "erro"
        adm_error "Comando falhou (rc=$rc): $*"
    fi

    return $rc
}

# ----------------------------------------------------------------------
# Comportamento ao ser executado diretamente (demo)
# ----------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Pequena demonstração
    adm_log_init
    adm_log_global_header

    adm_log_set_program_context \
        "demo-program" "1.2.3" "apps" \
        "dep1, dep2" "hook-pre, hook-post" "000-fix.patch" \
        "/usr/src/adm/repo/apps/demo-program" \
        "/usr/src/adm/work/demo-program-1.2.3" \
        "/usr/src/adm/cache/bin/apps/demo-program/1.2.3" \
        "$ADM_LOG_PATH"

    adm_log_program_header

    adm_info "Iniciando demonstração de log."
    adm_warn "Isso é apenas um teste, não um build real."

    adm_run_with_spinner "Simulando tarefa longa..." bash -c 'sleep 2'

    adm_success "Demonstração concluída com sucesso."
fi
