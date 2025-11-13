#!/usr/bin/env bash
# lib/adm/log.sh
#
# Sistema de logging centralizado para o ADM.
# - Suporte a níveis de log (DEBUG, INFO, BUILD, STAGE, FETCH, DETECT,
#   UPDATE, CLEANUP, VERIFY, CHROOT, PKG, WARN, ERROR).
# - Suporte a cores com detecção automática de TTY.
# - Saída principal em stderr, opcionalmente também em arquivo de log.
# - Sem "erros silenciosos": valores inválidos geram mensagens claras
#   mas nunca quebram o shell chamador.
###############################################################################
# Configuração padrão
###############################################################################
# Nível de log padrão (pode ser sobrescrito por ADM_LOG_LEVEL no ambiente)
: "${ADM_LOG_LEVEL:=INFO}"
# Mostrar timestamp? (1 = sim, 0 = não). Pode ser sobrescrito por ADM_LOG_TIMESTAMP.
: "${ADM_LOG_TIMESTAMP:=1}"
# Modo de cor:
#   auto  - habilita cores somente em TTY (padrão)
#   always- sempre usa cores
#   never - nunca usa cores
: "${ADM_COLOR_MODE:=auto}"
# Arquivo de log (sem cores). Pode ser definido externamente.
: "${ADM_LOG_FILE:=}"
# Variáveis internas (não altere diretamente)
ADM_LOG_LEVEL_NUM=0
ADM_LOG_USE_COLOR=0
ADM_LOG_COLOR_RESET=""
ADM_LOG_COLOR_DEBUG=""
ADM_LOG_COLOR_INFO=""
ADM_LOG_COLOR_BUILD=""
ADM_LOG_COLOR_STAGE=""
ADM_LOG_COLOR_FETCH=""
ADM_LOG_COLOR_DETECT=""
ADM_LOG_COLOR_UPDATE=""
ADM_LOG_COLOR_CLEANUP=""
ADM_LOG_COLOR_VERIFY=""
ADM_LOG_COLOR_CHROOT=""
ADM_LOG_COLOR_PKG=""
ADM_LOG_COLOR_WARN=""
ADM_LOG_COLOR_ERROR=""

ADM_LOG_SHOW_TIMESTAMP="$ADM_LOG_TIMESTAMP"
###############################################################################
# Helpers internos (não use diretamente fora deste arquivo)
###############################################################################
# Converte nível de log textual em valor numérico (para comparação de severidade).
# Quanto maior o número, mais severo.
adm__log_level_to_num() {
    case "$1" in
        DEBUG)   printf '10\n' ;;
        INFO)    printf '20\n' ;;
        BUILD)   printf '25\n' ;;
        STAGE)   printf '25\n' ;;
        FETCH)   printf '25\n' ;;
        DETECT)  printf '25\n' ;;
        UPDATE)  printf '25\n' ;;
        CLEANUP) printf '25\n' ;;
        VERIFY)  printf '25\n' ;;
        CHROOT)  printf '25\n' ;;
        PKG)     printf '25\n' ;;
        WARN)    printf '30\n' ;;
        ERROR)   printf '40\n' ;;
        *)
            # Não usar adm_log aqui para evitar recursão.
            printf '20\n'  # fallback INFO
            >&2 printf 'ADM-LOG WARNING: nível de log desconhecido: "%s"\n' "$1"
            ;;
    esac
}

# Retorna prefixo textual do nível, por ex: "[INFO]"
adm__log_prefix() {
    case "$1" in
        DEBUG)   printf '[DEBUG]'   ;;
        INFO)    printf '[INFO]'    ;;
        BUILD)   printf '[BUILD]'   ;;
        STAGE)   printf '[STAGE]'   ;;
        FETCH)   printf '[FETCH]'   ;;
        DETECT)  printf '[DETECT]'  ;;
        UPDATE)  printf '[UPDATE]'  ;;
        CLEANUP) printf '[CLEANUP]' ;;
        VERIFY)  printf '[VERIFY]'  ;;
        CHROOT)  printf '[CHROOT]'  ;;
        PKG)     printf '[PKG]'     ;;
        WARN)    printf '[WARN]'    ;;
        ERROR)   printf '[ERROR]'   ;;
        *)
            printf '[INFO]' ;;
    esac
}

# Define esquema de cores baseado em ADM_LOG_USE_COLOR
adm__log_init_colors() {
    if [ "$ADM_LOG_USE_COLOR" -eq 1 ]; then
        ADM_LOG_COLOR_RESET=$'\033[0m'
        # Cores escolhidas para boa legibilidade em fundos claros/escuros
        ADM_LOG_COLOR_DEBUG=$'\033[2;37m'   # cinza claro (faint)
        ADM_LOG_COLOR_INFO=$'\033[1;37m'    # branco forte
        ADM_LOG_COLOR_BUILD=$'\033[1;34m'   # azul
        ADM_LOG_COLOR_STAGE=$'\033[1;36m'   # ciano
        ADM_LOG_COLOR_FETCH=$'\033[0;36m'   # ciano leve
        ADM_LOG_COLOR_DETECT=$'\033[0;35m'  # magenta
        ADM_LOG_COLOR_UPDATE=$'\033[1;35m'  # magenta forte
        ADM_LOG_COLOR_CLEANUP=$'\033[0;32m' # verde
        ADM_LOG_COLOR_VERIFY=$'\033[1;32m'  # verde forte
        ADM_LOG_COLOR_CHROOT=$'\033[0;33m'  # amarelo
        ADM_LOG_COLOR_PKG=$'\033[0;34m'     # azul leve
        ADM_LOG_COLOR_WARN=$'\033[1;33m'    # amarelo forte
        ADM_LOG_COLOR_ERROR=$'\033[1;31m'   # vermelho forte
    else
        ADM_LOG_COLOR_RESET=""
        ADM_LOG_COLOR_DEBUG=""
        ADM_LOG_COLOR_INFO=""
        ADM_LOG_COLOR_BUILD=""
        ADM_LOG_COLOR_STAGE=""
        ADM_LOG_COLOR_FETCH=""
        ADM_LOG_COLOR_DETECT=""
        ADM_LOG_COLOR_UPDATE=""
        ADM_LOG_COLOR_CLEANUP=""
        ADM_LOG_COLOR_VERIFY=""
        ADM_LOG_COLOR_CHROOT=""
        ADM_LOG_COLOR_PKG=""
        ADM_LOG_COLOR_WARN=""
        ADM_LOG_COLOR_ERROR=""
    fi
}

# Retorna código de cor para o nível
adm__log_color() {
    case "$1" in
        DEBUG)   printf '%s' "$ADM_LOG_COLOR_DEBUG"   ;;
        INFO)    printf '%s' "$ADM_LOG_COLOR_INFO"    ;;
        BUILD)   printf '%s' "$ADM_LOG_COLOR_BUILD"   ;;
        STAGE)   printf '%s' "$ADM_LOG_COLOR_STAGE"   ;;
        FETCH)   printf '%s' "$ADM_LOG_COLOR_FETCH"   ;;
        DETECT)  printf '%s' "$ADM_LOG_COLOR_DETECT"  ;;
        UPDATE)  printf '%s' "$ADM_LOG_COLOR_UPDATE"  ;;
        CLEANUP) printf '%s' "$ADM_LOG_COLOR_CLEANUP" ;;
        VERIFY)  printf '%s' "$ADM_LOG_COLOR_VERIFY"  ;;
        CHROOT)  printf '%s' "$ADM_LOG_COLOR_CHROOT"  ;;
        PKG)     printf '%s' "$ADM_LOG_COLOR_PKG"     ;;
        WARN)    printf '%s' "$ADM_LOG_COLOR_WARN"    ;;
        ERROR)   printf '%s' "$ADM_LOG_COLOR_ERROR"   ;;
        *)
            printf '%s' "$ADM_LOG_COLOR_INFO" ;;
    esac
}

# Decide se deve usar cor com base em ADM_COLOR_MODE e TTY
adm__log_detect_color_support() {
    case "$ADM_COLOR_MODE" in
        always)
            ADM_LOG_USE_COLOR=1
            ;;
        never)
            ADM_LOG_USE_COLOR=0
            ;;
        auto|*)
            if [ -t 2 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
                ADM_LOG_USE_COLOR=1
            else
                ADM_LOG_USE_COLOR=0
            fi
            ;;
    esac
}

# Atualiza ADM_LOG_LEVEL_NUM a partir de ADM_LOG_LEVEL
adm__log_update_level_num() {
    ADM_LOG_LEVEL_NUM="$(adm__log_level_to_num "$ADM_LOG_LEVEL")"
}
###############################################################################
# API pública
###############################################################################
# Inicializa subsistema de log.
# Pode ser chamada explicitamente, mas também roda automaticamente ao carregar.
adm_log_init() {
    # Atualiza numérico do nível de log
    adm__log_update_level_num

    # Detecta suporte a cor e inicializa esquema de cores
    adm__log_detect_color_support
    adm__log_init_colors

    # Normaliza flag de timestamp
    if [ "$ADM_LOG_SHOW_TIMESTAMP" != "0" ]; then
        ADM_LOG_SHOW_TIMESTAMP=1
    fi
}

# Define nível de log em tempo de execução.
# Exemplo: adm_log_set_level DEBUG
adm_log_set_level() {
    if [ $# -ne 1 ]; then
        >&2 printf 'ADM-LOG ERROR: adm_log_set_level requer exatamente 1 argumento (LEVEL)\n'
        return 1
    fi

    ADM_LOG_LEVEL="$1"
    adm__log_update_level_num
}

# Define arquivo de log.
# Exemplo: adm_log_set_logfile "/var/log/adm/main.log"
adm_log_set_logfile() {
    if [ $# -ne 1 ]; then
        >&2 printf 'ADM-LOG ERROR: adm_log_set_logfile requer exatamente 1 argumento (PATH)\n'
        return 1
    fi

    ADM_LOG_FILE="$1"
}

# Habilita ou desabilita timestamps.
# Exemplo: adm_log_enable_timestamps 0
adm_log_enable_timestamps() {
    if [ $# -ne 1 ]; then
        >&2 printf 'ADM-LOG ERROR: adm_log_enable_timestamps requer exatamente 1 argumento (0|1)\n'
        return 1
    fi

    case "$1" in
        0|1)
            ADM_LOG_SHOW_TIMESTAMP="$1"
            ;;
        *)
            >&2 printf 'ADM-LOG ERROR: valor inválido para adm_log_enable_timestamps: "%s" (use 0 ou 1)\n' "$1"
            return 1
            ;;
    esac
}

# Função principal de log.
# Uso: adm_log LEVEL mensagem...
adm_log() {
    if [ $# -lt 2 ]; then
        >&2 printf 'ADM-LOG ERROR: adm_log requer pelo menos 2 argumentos: LEVEL e MENSAGEM\n'
        return 1
    fi

    local level="$1"
    shift

    # Mensagem bruta (como foi passada)
    local msg
    msg="$*"

    # Converte nível para número e decide se loga ou ignora
    local lvl_num
    lvl_num="$(adm__log_level_to_num "$level")"

    # Se menor que o nível configurado, ignora silenciosamente
    if [ "$lvl_num" -lt "$ADM_LOG_LEVEL_NUM" ]; then
        return 0
    fi

    # Timestamp opcional
    local ts=""
    if [ "$ADM_LOG_SHOW_TIMESTAMP" -eq 1 ]; then
        # date pode falhar em ambientes extremamente restritos, mas isso é raro.
        # Em caso de falha, ts fica vazio sem quebrar nada.
        ts="[$(date +'%Y-%m-%d %H:%M:%S' 2>/dev/null)] "
    fi

    local prefix color reset
    prefix="$(adm__log_prefix "$level")"
    color="$(adm__log_color "$level")"
    reset="$ADM_LOG_COLOR_RESET"

    local line
    line="${ts}${prefix} ${msg}"

    # Saída colorida em stderr (se habilitado)
    if [ "$ADM_LOG_USE_COLOR" -eq 1 ] && [ -n "$color" ] && [ -n "$reset" ]; then
        printf '%b\n' "${color}${line}${reset}" >&2
    else
        printf '%s\n' "$line" >&2
    fi

    # Opcionalmente log em arquivo (sem cores)
    if [ -n "$ADM_LOG_FILE" ]; then
        # Não falha se não conseguir escrever no arquivo.
        {
            printf '%s\n' "$line"
        } >>"$ADM_LOG_FILE" 2>/dev/null || :
    fi

    return 0
}
###############################################################################
# Funções convenientes por nível (wrappers)
###############################################################################
adm_log_debug()   { adm_log DEBUG   "$@"; }
adm_log_info()    { adm_log INFO    "$@"; }
adm_log_build()   { adm_log BUILD   "$@"; }
adm_log_stage()   { adm_log STAGE   "$@"; }
adm_log_fetch()   { adm_log FETCH   "$@"; }
adm_log_detect()  { adm_log DETECT  "$@"; }
adm_log_update()  { adm_log UPDATE  "$@"; }
adm_log_cleanup() { adm_log CLEANUP "$@"; }
adm_log_verify()  { adm_log VERIFY  "$@"; }
adm_log_chroot()  { adm_log CHROOT  "$@"; }
adm_log_pkg()     { adm_log PKG     "$@"; }
adm_log_warn()    { adm_log WARN    "$@"; }
adm_log_error()   { adm_log ERROR   "$@"; }
###############################################################################
# Inicialização automática ao carregar o arquivo
###############################################################################
adm_log_init
