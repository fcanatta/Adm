#!/usr/bin/env bash
# 02-lib.sh - Funções comuns: log, erro, spinner, metafile, locks
# Deve ser *sourced* pelos outros scripts:
#   . /usr/src/adm/scripts/02-lib.sh

# Impedir execução direta
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Este script deve ser 'sourced', não executado diretamente." >&2
    exit 1
fi

# Guard para evitar carregar duas vezes
if [[ -n "${ADM_LIB_LOADED:-}" ]]; then
    return 0
fi

# Garantir env
if [[ -z "${ADM_ENV_LOADED:-}" ]]; then
    if [[ -f /usr/src/adm/scripts/01-env.sh ]]; then
        # shellcheck disable=SC1091
        . /usr/src/adm/scripts/01-env.sh
    else
        echo "ERRO: 01-env.sh não encontrado em /usr/src/adm/scripts." >&2
        return 1
    fi
fi

###############################################################################
# 1. Cores e log
###############################################################################

ADM_COLOR_RESET=""
ADM_COLOR_DEBUG=""
ADM_COLOR_INFO=""
ADM_COLOR_WARN=""
ADM_COLOR_ERROR=""

if [[ -t 1 ]]; then
    ADM_COLOR_RESET=$'\033[0m'
    ADM_COLOR_DEBUG=$'\033[36m' # ciano
    ADM_COLOR_INFO=$'\033[32m'  # verde
    ADM_COLOR_WARN=$'\033[33m'  # amarelo
    ADM_COLOR_ERROR=$'\033[31m' # vermelho
fi

: "${ADM_LOG_CTX:=$(basename "${0:-adm}")}"

ADM_LOG_FILE=""

adm_init_log() {
    local ctx="${1:-$ADM_LOG_CTX}"
    ADM_LOG_CTX="$ctx"
    ADM_LOG_FILE="${ADM_LOGS}/${ADM_LOG_CTX}.log"

    mkdir -p "${ADM_LOGS}" 2>/dev/null || true

    {
        echo "================================================================"
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${ADM_LOG_CTX}] INÍCIO DO LOG"
        echo "================================================================"
    } >> "${ADM_LOG_FILE}" 2>/dev/null || true
}

adm__log_raw() {
    local level="$1"; shift || true
    local color=""
    local ts msg

    case "$level" in
        DEBUG) color="${ADM_COLOR_DEBUG}" ;;
        INFO)  color="${ADM_COLOR_INFO}" ;;
        WARN)  color="${ADM_COLOR_WARN}" ;;
        ERROR) color="${ADM_COLOR_ERROR}" ;;
        *)     color="${ADM_COLOR_RESET}" ;;
    esac

    ts="$(date +'%Y-%m-%d %H:%M:%S')" || ts="????-??-?? ??:??:??"
    msg="$*"

    # Saída na tela
    printf '%s[%s] [%s] [%s]%s %s\n' \
        "$color" "$ts" "$ADM_LOG_CTX" "$level" "$ADM_COLOR_RESET" "$msg" >&2

    # Registro em log, se configurado
    if [[ -n "${ADM_LOG_FILE:-}" ]]; then
        printf '[%s] [%s] [%s] %s\n' "$ts" "$ADM_LOG_CTX" "$level" "$msg" >> "${ADM_LOG_FILE}" 2>/dev/null || true
    fi
}

adm_debug() { adm__log_raw "DEBUG" "$@"; }
adm_info()  { adm__log_raw "INFO"  "$@"; }
adm_warn()  { adm__log_raw "WARN"  "$@"; }
adm_error() { adm__log_raw "ERROR" "$@"; }

adm_die() {
    local code="${1:-1}"
    shift || true
    adm_error "$@"
    return "$code"
}

###############################################################################
# 2. Tratamento de erro / modo estrito (opt-in)
###############################################################################

adm_enable_strict_mode() {
    # Para ser chamado pelos scripts principais, não aqui automaticamente
    set -euo pipefail

    trap 'adm_trap_err ${LINENO} "$BASH_COMMAND"' ERR
    trap 'adm_trap_int' INT TERM
}

adm_trap_err() {
    local lineno="$1"
    local cmd="$2"
    adm_error "Erro na linha ${lineno}: comando falhou: ${cmd}"
}

adm_trap_int() {
    adm_warn "Interrompido pelo usuário ou sinal externo."
    exit 130
}

###############################################################################
# 3. Spinner / execução com feedback
###############################################################################

ADM_SPINNER_CHARS='-\|/'

adm_run_with_spinner() {
    # Uso: adm_run_with_spinner "Mensagem" comando args...
    local msg="$1"; shift
    local pid spin i=0
    local delay=0.1

    adm_info "${msg}"

    ("$@") &
    pid=$!

    # spinner só se stdout for terminal
    if [[ -t 1 ]]; then
        while kill -0 "$pid" 2>/dev/null; do
            i=$(( (i + 1) % 4 ))
            printf '\r[%s] %s' "${ADM_SPINNER_CHARS:$i:1}" "${msg}" >&2
            sleep "$delay"
        done
        printf '\r    \r' >&2
    else
        wait "$pid"
        return $?
    fi

    wait "$pid"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        adm_error "Falha ao executar: $* (rc=${rc})"
    else
        adm_info "Concluído: ${msg}"
    fi
    return "$rc"
}

###############################################################################
# 4. Locks simples (para evitar corridas)
###############################################################################

ADM_LOCK_DIR="${ADM_ROOT}/locks"

adm_lock_acquire() {
    local name="$1"
    local lockdir="${ADM_LOCK_DIR}/${name}.lock"
    mkdir -p "${ADM_LOCK_DIR}" 2>/dev/null || true

    local timeout=60
    local waited=0

    while ! mkdir "${lockdir}" 2>/dev/null; do
        if (( waited >= timeout )); then
            adm_error "Timeout ao aguardar lock '${name}'."
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    echo "$$" > "${lockdir}/pid" 2>/dev/null || true
    return 0
}

adm_lock_release() {
    local name="$1"
    local lockdir="${ADM_LOCK_DIR}/${name}.lock"
    if [[ -d "${lockdir}" ]]; then
        rm -rf "${lockdir}" 2>/dev/null || true
    fi
}
###############################################################################
# 5. Metafile: leitura, criação e helpers
#
# Formato exigido:
# name=programa
# version=1.2.3
# category=apps|libs|sys|dev|x11|wayland|
# run_deps=dep1,dep2
# build_deps=depA,depB
# opt_deps=depX,depY
# num_builds=0
# description=Descrição curta
# homepage=https://...
# maintainer=Nome <email>
# sha256sums=sum1,sum2
# md5sum=sum1,sum2
# sources=url1,url2
###############################################################################

# Variáveis globais de metafile
ADM_META_PATH=""
ADM_META_name=""
ADM_META_version=""
ADM_META_category=""
ADM_META_run_deps=""
ADM_META_build_deps=""
ADM_META_opt_deps=""
ADM_META_num_builds="0"
ADM_META_description=""
ADM_META_homepage=""
ADM_META_maintainer=""
ADM_META_sha256sums=""
ADM_META_md5sum=""
ADM_META_sources=""

adm_meta_reset() {
    ADM_META_PATH=""
    ADM_META_name=""
    ADM_META_version=""
    ADM_META_category=""
    ADM_META_run_deps=""
    ADM_META_build_deps=""
    ADM_META_opt_deps=""
    ADM_META_num_builds="0"
    ADM_META_description=""
    ADM_META_homepage=""
    ADM_META_maintainer=""
    ADM_META_sha256sums=""
    ADM_META_md5sum=""
    ADM_META_sources=""
}

adm_meta_load() {
    # Uso: adm_meta_load <arquivo|diretório>
    local path="$1"

    if [[ -d "$path" ]]; then
        path="${path%/}/metafile"
    fi

    if [[ ! -f "$path" ]]; then
        adm_die 1 "Metafile não encontrado em '$path'."
        return 1
    fi

    adm_meta_reset
    ADM_META_PATH="$path"

    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Ignorar linhas vazias e comentários
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # chave=valor (apenas primeira '=')
        key="${line%%=*}"
        val="${line#*=}"

        key="${key//[[:space:]]/}"  # remove espaços do key
        val="${val#"${val%%[![:space:]]*}"}"  # trim left
        val="${val%"${val##*[![:space:]]}"}"  # trim right

        case "$key" in
            name)         ADM_META_name="$val" ;;
            version)      ADM_META_version="$val" ;;
            category)     ADM_META_category="$val" ;;
            run_deps)     ADM_META_run_deps="$val" ;;
            build_deps)   ADM_META_build_deps="$val" ;;
            opt_deps)     ADM_META_opt_deps="$val" ;;
            num_builds)   ADM_META_num_builds="$val" ;;
            description)  ADM_META_description="$val" ;;
            homepage)     ADM_META_homepage="$val" ;;
            maintainer)   ADM_META_maintainer="$val" ;;
            sha256sums)   ADM_META_sha256sums="$val" ;;
            md5sum)       ADM_META_md5sum="$val" ;;
            sources)      ADM_META_sources="$val" ;;
            *)
                adm_warn "Chave desconhecida no metafile: '${key}' (linha: '${line}')"
                ;;
        esac
    done < "$path"

    adm_meta_validate || return 1

    adm_info "Metafile carregado: ${ADM_META_name}-${ADM_META_version} (${ADM_META_category})"
    return 0
}

adm_meta_validate() {
    local rc=0

    if [[ -z "${ADM_META_name}" ]]; then
        adm_error "Metafile inválido: 'name' vazio."
        rc=1
    fi
    if [[ -z "${ADM_META_version}" ]]; then
        adm_error "Metafile inválido: 'version' vazio."
        rc=1
    fi
    if [[ -z "${ADM_META_category}" ]]; then
        adm_error "Metafile inválido: 'category' vazio."
        rc=1
    fi
    if [[ -z "${ADM_META_sources}" ]]; then
        adm_error "Metafile inválido: 'sources' vazio."
        rc=1
    fi

    # Categoria
    case "${ADM_META_category}" in
        apps|libs|sys|dev|x11|wayland) : ;;
        *)
            adm_error "Categoria inválida: '${ADM_META_category}' (aceito: apps|libs|sys|dev|x11|wayland)"
            rc=1
            ;;
    esac

    # num_builds numérico
    if ! [[ "${ADM_META_num_builds}" =~ ^[0-9]+$ ]]; then
        adm_warn "Campo 'num_builds' inválido '${ADM_META_num_builds}', ajustando para 0."
        ADM_META_num_builds="0"
    fi

    return "$rc"
}

adm_meta_get() {
    # Uso: adm_meta_get <campo>
    local field="$1"
    case "$field" in
        name)         echo "${ADM_META_name}" ;;
        version)      echo "${ADM_META_version}" ;;
        category)     echo "${ADM_META_category}" ;;
        run_deps)     echo "${ADM_META_run_deps}" ;;
        build_deps)   echo "${ADM_META_build_deps}" ;;
        opt_deps)     echo "${ADM_META_opt_deps}" ;;
        num_builds)   echo "${ADM_META_num_builds}" ;;
        description)  echo "${ADM_META_description}" ;;
        homepage)     echo "${ADM_META_homepage}" ;;
        maintainer)   echo "${ADM_META_maintainer}" ;;
        sha256sums)   echo "${ADM_META_sha256sums}" ;;
        md5sum)       echo "${ADM_META_md5sum}" ;;
        sources)      echo "${ADM_META_sources}" ;;
        path)         echo "${ADM_META_PATH}" ;;
        *)
            adm_die 1 "Campo de metafile desconhecido: '${field}'"
            ;;
    esac
}

adm_meta_create_skeleton() {
    # Uso: adm_meta_create_skeleton <caminho_metafile>
    local path="$1"
    local dir
    dir="$(dirname "$path")"

    mkdir -p "$dir" || {
        adm_die 1 "Não foi possível criar diretório para metafile: '$dir'"
        return 1
    }

    if [[ -e "$path" ]]; then
        adm_warn "Metafile '${path}' já existe, não será sobrescrito."
        return 0
    fi

    cat > "$path" <<'EOF'
name=programa
version=1.2.3
category=apps
run_deps=
build_deps=
opt_deps=
num_builds=0
description=Descrição curta
homepage=https://...
maintainer=Nome <email>
sha256sums=
md5sum=
sources=
EOF

    adm_info "Metafile skeleton criado em: ${path}"
}

adm_meta_increment_builds() {
    # Incrementa num_builds em memória; 04-build-pkg.sh decide persistir
    local n="${ADM_META_num_builds:-0}"
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
        n=0
    fi
    n=$(( n + 1 ))
    ADM_META_num_builds="$n"
}

###############################################################################
# 6. Helpers de lista (deps, sources)
###############################################################################

adm_split_csv_to_array() {
    # Uso: adm_split_csv_to_array "a,b,c" nome_da_array
    local csv="$1"
    local arr_name="$2"
    local IFS=','

    read -r -a "$arr_name" <<< "$csv"
}

adm_meta_get_run_deps_array() {
    local __name="$1"
    adm_split_csv_to_array "${ADM_META_run_deps}" "$__name"
}

adm_meta_get_build_deps_array() {
    local __name="$1"
    adm_split_csv_to_array "${ADM_META_build_deps}" "$__name"
}

adm_meta_get_opt_deps_array() {
    local __name="$1"
    adm_split_csv_to_array "${ADM_META_opt_deps}" "$__name"
}

adm_meta_get_sources_array() {
    local __name="$1"
    adm_split_csv_to_array "${ADM_META_sources}" "$__name"
}

###############################################################################
# Final
###############################################################################

ADM_LIB_LOADED=1
export ADM_LIB_LOADED

# Inicializa log padrão se não estiver inicializado
if [[ -z "${ADM_LOG_FILE:-}" ]]; then
    adm_init_log "adm"
fi

adm_debug "02-lib.sh carregado com sucesso."
