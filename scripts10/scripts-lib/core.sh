#!/usr/bin/env bash
# lib/adm/core.sh
#
# Núcleo de utilitários do ADM:
#  - Inicialização de caminhos (ADM_ROOT, ADM_REPO_DIR, ADM_LOG_DIR, etc.)
#  - Funções de verificação (root, arquivos, diretórios)
#  - Criação segura de diretórios e remoções seguras
#  - Execução de comandos com logging
#  - Locks simples para evitar concorrência
#  - Leitura de arquivos chave=valor
#
# Objetivo: zero erros silenciosos – qualquer uso incorreto ou falha relevante
# gera mensagem clara via adm_log_* ou stderr.
###############################################################################
# Dependência: log.sh
###############################################################################
# Se adm_log não existir, cria um stub simples para evitar falhas.
if ! command -v adm_log >/dev/null 2>&1; then
    adm_log() {
        # fallback minimalista: sem níveis, só despeja no stderr
        printf '%s\n' "$*" >&2
    }
    adm_log_warn()  { adm_log "[WARN]  $*"; }
    adm_log_error() { adm_log "[ERROR] $*"; }
    adm_log_info()  { adm_log "[INFO]  $*"; }
    adm_log_debug() { :; }
    adm_log_build()   { adm_log "[BUILD] $*"; }
    adm_log_stage()   { adm_log "[STAGE] $*"; }
    adm_log_fetch()   { adm_log "[FETCH] $*"; }
    adm_log_detect()  { adm_log "[DETECT] $*"; }
    adm_log_update()  { adm_log "[UPDATE] $*"; }
    adm_log_cleanup() { adm_log "[CLEANUP] $*"; }
    adm_log_verify()  { adm_log "[VERIFY] $*"; }
    adm_log_chroot()  { adm_log "[CHROOT] $*"; }
    adm_log_pkg()     { adm_log "[PKG] $*"; }
fi
###############################################################################
# Configuração global de caminhos
###############################################################################
# Diretório base do ADM (por padrão, dois níveis acima deste arquivo: /usr/src/adm)
adm_core_detect_root() {
    if [ -n "${ADM_ROOT:-}" ]; then
        printf '%s\n' "$ADM_ROOT"
        return 0
    fi

    # BASH_SOURCE funciona em bash; se não funcionar, volta para pwd.
    local lib_dir
    if [ -n "${BASH_SOURCE[0]:-}" ]; then
        lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || lib_dir=""
    else
        lib_dir="$(pwd 2>/dev/null)" || lib_dir=""
    fi

    if [ -z "$lib_dir" ]; then
        adm_log_error "Não foi possível determinar o diretório da biblioteca do ADM."
        printf '/usr/src/adm\n'
        return 1
    fi

    # lib/adm → raiz é ../..
    local root
    root="$(cd "$lib_dir/../.." 2>/dev/null && pwd)" || root=""

    if [ -z "$root" ]; then
        adm_log_error "Não foi possível determinar ADM_ROOT a partir de '$lib_dir'."
        printf '/usr/src/adm\n'
        return 1
    fi

    printf '%s\n' "$root"
    return 0
}

# Inicializa variáveis padrão de caminho.
adm_core_init_paths() {
    # ADM_ROOT pode ser definido fora; se não, detecta.
    ADM_ROOT="$(adm_core_detect_root)" || :
    export ADM_ROOT

    : "${ADM_REPO_DIR:="$ADM_ROOT/repo"}"
    : "${ADM_CACHE_DIR:="$ADM_ROOT/cache"}"
    : "${ADM_BUILD_CACHE_DIR:="$ADM_CACHE_DIR/build"}"
    : "${ADM_SOURCE_CACHE_DIR:="$ADM_CACHE_DIR/sources"}"
    : "${ADM_DESTDIR_DIR:="$ADM_ROOT/destdir"}"
    : "${ADM_LOG_DIR:="$ADM_ROOT/logs"}"
    : "${ADM_STATE_DIR:="$ADM_ROOT/state"}"
    : "${ADM_LOCK_DIR:="$ADM_STATE_DIR/locks"}"
    : "${ADM_PROFILES_DIR:="$ADM_ROOT/profiles"}"
    : "${ADM_CONFIG_DIR:="$ADM_ROOT/config"}"
    : "${ADM_UPDATES_DIR:="$ADM_ROOT/updates"}"
    : "${ADM_ROOTFS_DIR:="$ADM_ROOT/rootfs"}"

    # Cria diretórios críticos se não existirem
    adm_mkdir_p "$ADM_LOG_DIR"      || adm_log_error "Falha ao criar ADM_LOG_DIR: $ADM_LOG_DIR"
    adm_mkdir_p "$ADM_STATE_DIR"    || adm_log_error "Falha ao criar ADM_STATE_DIR: $ADM_STATE_DIR"
    adm_mkdir_p "$ADM_LOCK_DIR"     || adm_log_error "Falha ao criar ADM_LOCK_DIR: $ADM_LOCK_DIR"
    adm_mkdir_p "$ADM_CACHE_DIR"    || adm_log_error "Falha ao criar ADM_CACHE_DIR: $ADM_CACHE_DIR"
    adm_mkdir_p "$ADM_BUILD_CACHE_DIR"   || adm_log_error "Falha ao criar ADM_BUILD_CACHE_DIR: $ADM_BUILD_CACHE_DIR"
    adm_mkdir_p "$ADM_SOURCE_CACHE_DIR"  || adm_log_error "Falha ao criar ADM_SOURCE_CACHE_DIR: $ADM_SOURCE_CACHE_DIR"
    adm_mkdir_p "$ADM_DESTDIR_DIR"  || adm_log_error "Falha ao criar ADM_DESTDIR_DIR: $ADM_DESTDIR_DIR"
    adm_mkdir_p "$ADM_PROFILES_DIR" || adm_log_error "Falha ao criar ADM_PROFILES_DIR: $ADM_PROFILES_DIR"
    adm_mkdir_p "$ADM_UPDATES_DIR"  || adm_log_error "Falha ao criar ADM_UPDATES_DIR: $ADM_UPDATES_DIR"
    adm_mkdir_p "$ADM_ROOTFS_DIR"   || adm_log_error "Falha ao criar ADM_ROOTFS_DIR: $ADM_ROOTFS_DIR"
}
###############################################################################
# Funções básicas de utilidade
###############################################################################
# Junta dois caminhos. Não faz normalização complexa.
# Uso: adm_path_join base sub
adm_path_join() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_path_join requer 2 argumentos: BASE SUB"
        return 1
    fi
    local base="$1" sub="$2"

    case "$sub" in
        /*)
            # Já é absoluto
            printf '%s\n' "$sub"
            ;;
        *)
            # Remove / final do base para evitar "//"
            base="${base%/}"
            printf '%s/%s\n' "$base" "$sub"
            ;;
    esac
}

# Retorna caminho absoluto (simplificado).
# Uso: adm_abspath caminho
adm_abspath() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_abspath requer 1 argumento: CAMINHO"
        return 1
    fi
    local path="$1"

    if [ -z "$path" ]; then
        adm_log_error "adm_abspath recebeu caminho vazio."
        return 1
    fi

    if [ "${path#/}" != "$path" ]; then
        # Já é absoluto
        printf '%s\n' "$path"
        return 0
    fi

    local dir
    dir="$(cd "$(dirname "$path")" 2>/dev/null && pwd)" || {
        adm_log_error "adm_abspath: não foi possível obter diretório de '$path'."
        return 1
    }

    printf '%s/%s\n' "$dir" "$(basename "$path")"
    return 0
}

# Cria diretório recursivamente de forma segura.
# Uso: adm_mkdir_p /caminho
adm_mkdir_p() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_mkdir_p requer 1 argumento: DIR"
        return 1
    fi
    local dir="$1"
    if [ -z "$dir" ]; then
        adm_log_error "adm_mkdir_p recebeu DIR vazio."
        return 1
    fi

    if [ -d "$dir" ]; then
        return 0
    fi

    if mkdir -p "$dir" 2>/dev/null; then
        return 0
    fi

    adm_log_error "Falha ao criar diretório: $dir"
    return 1
}

# Verifica se é root.
adm_is_root() {
    [ "$(id -u 2>/dev/null)" = "0" ]
}

# Requer root – retorna 0 se root, 1 se não.
adm_require_root() {
    if ! adm_is_root; then
        adm_log_error "Este comando requer privilégios de root."
        return 1
    fi
    return 0
}

# Função de saída fatal para CLI: loga erro e sai.
# Uso: adm_die "mensagem"
adm_die() {
    if [ $# -eq 0 ]; then
        adm_log_error "adm_die chamado sem mensagem."
        exit 1
    fi
    adm_log_error "$*"
    exit 1
}

###############################################################################
# Execução de comandos com logging
###############################################################################

# Executa comando mostrando-o antes (shell-like).
# Uso: adm_run comando arg1 arg2...
adm_run() {
    if [ $# -lt 1 ]; then
        adm_log_error "adm_run requer pelo menos 1 argumento (comando)."
        return 1
    fi

    adm_log_debug "Executando comando: $*"
    "$@"
    local rc=$?
    if [ $rc -ne 0 ]; then
        adm_log_error "Comando falhou (rc=$rc): $*"
    fi
    return $rc
}

# Executa comando e falha de forma explícita se der erro.
# Uso: adm_run_or_die comando arg1 arg2...
adm_run_or_die() {
    if [ $# -lt 1 ]; then
        adm_die "adm_run_or_die requer pelo menos 1 argumento (comando)."
    fi

    adm_run "$@" || adm_die "Comando obrigatório falhou: $*"
}

# Executa comando suprimindo saída, mas logando erro se falhar.
# Uso: adm_run_quiet comando arg1 arg2...
adm_run_quiet() {
    if [ $# -lt 1 ]; then
        adm_log_error "adm_run_quiet requer pelo menos 1 argumento (comando)."
        return 1
    fi

    "$@" >/dev/null 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then
        adm_log_error "Comando (quiet) falhou (rc=$rc): $*"
    fi
    return $rc
}

###############################################################################
# Remoção segura de caminhos
###############################################################################

# Verifica se um caminho é "perigoso" para rm -rf.
# Retorna 0 SE FOR SEGURO, 1 se for perigoso.
adm_is_safe_rm_target() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_is_safe_rm_target requer 1 argumento: CAMINHO"
        return 1
    fi
    local path="$1"

    # Vazio é perigoso
    if [ -z "$path" ]; then
        adm_log_error "Caminho vazio não é seguro para rm -rf."
        return 1
    fi

    # Normaliza caminho relativo para absoluto
    local abs
    abs="$(adm_abspath "$path")" || return 1

    case "$abs" in
        /|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib64|/etc)
            adm_log_error "Caminho potencialmente crítico não é permitido para rm -rf: $abs"
            return 1
            ;;
    esac

    # Se ADM_ROOT estiver definido, opcionalmente podemos só permitir abaixo dele.
    if [ -n "${ADM_ROOT:-}" ]; then
        case "$abs" in
            "$ADM_ROOT"/*|"$ADM_ROOT")
                # ok – dentro da árvore do ADM
                ;;
            *)
                adm_log_warn "Caminho fora de ADM_ROOT: $abs (permitido, mas cuidado)."
                ;;
        esac
    fi

    return 0
}

# rm -rf com checagem de segurança.
# Uso: adm_rm_rf_safe CAMINHO
adm_rm_rf_safe() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_rm_rf_safe requer 1 argumento: CAMINHO"
        return 1
    fi

    local path="$1"
    if ! adm_is_safe_rm_target "$path"; then
        return 1
    fi

    if [ ! -e "$path" ]; then
        # Nada a remover; não é erro fatal.
        adm_log_debug "adm_rm_rf_safe: caminho não existe: $path"
        return 0
    fi

    rm -rf -- "$path"
    local rc=$?
    if [ $rc -ne 0 ]; then
        adm_log_error "Falha ao remover caminho: $path"
        return $rc
    fi
    return 0
}

###############################################################################
# Diretórios temporários
###############################################################################

# Cria um diretório temporário para uso do ADM.
# Uso: adm_tmpdir_create [prefix]
# Retorna no stdout o caminho do tmpdir.
adm_tmpdir_create() {
    local prefix="${1:-adm}"
    local tmp

    # Usa mktemp -d se houver
    if command -v mktemp >/dev/null 2>&1; then
        tmp="$(mktemp -d -t "${prefix}.XXXXXX" 2>/dev/null)" || tmp=""
    else
        # Fallback bem simples: usa ADM_STATE_DIR/tmp
        local base="${ADM_STATE_DIR:-/tmp}"
        adm_mkdir_p "$base/tmp" || base="/tmp"
        tmp="$base/tmp/${prefix}.$$.$RANDOM"
        mkdir -p "$tmp" 2>/dev/null || tmp=""
    fi

    if [ -z "$tmp" ]; then
        adm_log_error "Falha ao criar diretório temporário."
        return 1
    fi

    printf '%s\n' "$tmp"
    return 0
}
###############################################################################
# Locks (simples)
###############################################################################
# Adquire um lock de nome lógico.
# Uso: adm_lock_acquire NOME [timeout_segundos]
# Retorna 0 se lock adquirido, 1 se não.
adm_lock_acquire() {
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
        adm_log_error "adm_lock_acquire requer 1 ou 2 argumentos: NOME [TIMEOUT]"
        return 1
    fi

    local name="$1"
    local timeout="${2:-30}"

    if [ -z "$name" ]; then
        adm_log_error "adm_lock_acquire: NOME não pode ser vazio."
        return 1
    fi

    adm_mkdir_p "$ADM_LOCK_DIR" || {
        adm_log_error "adm_lock_acquire: não foi possível criar ADM_LOCK_DIR."
        return 1
    }

    local lockfile="$ADM_LOCK_DIR/$name.lock"

    # Se flock existir, usa. Caso contrário, fallback com mkdir.
    if command -v flock >/dev/null 2>&1; then
        # Abre descritor de arquivo exclusivo
        # shellcheck disable=SC3028,SC3030
        exec {ADM_LOCK_FD}>"$lockfile" 2>/dev/null || {
            adm_log_error "adm_lock_acquire: não foi possível abrir lockfile: $lockfile"
            return 1
        }

        if [ "$timeout" -gt 0 ] 2>/dev/null; then
            if ! flock -w "$timeout" "$ADM_LOCK_FD"; then
                adm_log_error "Timeout ao aguardar lock: $name"
                return 1
            fi
        else
            if ! flock -n "$ADM_LOCK_FD"; then
                adm_log_error "Lock em uso: $name"
                return 1
            fi
        fi

        adm_log_debug "Lock adquirido (flock): $name"
        # FD fica aberto até o processo terminar ou lock ser liberado manualmente.
        return 0
    else
        # Fallback com mkdir
        local start_ts now_ts
        start_ts="$(date +%s 2>/dev/null || echo 0)"

        while :; do
            if mkdir "$lockfile" 2>/dev/null; then
                adm_log_debug "Lock adquirido (mkdir): $name"
                return 0
            fi

            if [ "$timeout" -le 0 ] 2>/dev/null; then
                adm_log_error "Lock em uso (sem timeout): $name"
                return 1
            fi

            now_ts="$(date +%s 2>/dev/null || echo 0)"
            if [ $((now_ts - start_ts)) -ge "$timeout" ]; then
                adm_log_error "Timeout ao aguardar lock (mkdir): $name"
                return 1
            fi
            sleep 1
        done
    fi
}
# Libera lock de nome lógico (modo mkdir fallback).
# No modo flock, o lock é liberado automaticamente ao encerrar o processo ou
# se o descritor for fechado; aqui só removemos o lockfile se ele for diretório.
adm_lock_release() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_lock_release requer 1 argumento: NOME"
        return 1
    fi

    local name="$1"
    if [ -z "$name" ]; then
        adm_log_error "adm_lock_release: NOME não pode ser vazio."
        return 1
    fi

    local lockfile="$ADM_LOCK_DIR/$name.lock"

    if [ -d "$lockfile" ]; then
        rmdir "$lockfile" 2>/dev/null || {
            adm_log_warn "adm_lock_release: não foi possível remover diretório de lock: $lockfile"
            return 1
        }
        adm_log_debug "Lock liberado (mkdir): $name"
    else
        # Se não é diretório, assume lock via flock; não apagamos arquivo.
        adm_log_debug "adm_lock_release: nada a fazer para lock '$name' (modo flock)."
    fi

    return 0
}
###############################################################################
# Leitura de arquivos chave=valor simples
###############################################################################
# Lê arquivo de config chave=valor e exporta variáveis com prefixo.
# Uso: adm_read_kv_file /caminho/arquivo PREFIXO_
# Exemplo de linha:
#   key=value
#   # comentário
#   key2 = value2 com espaços
#
# Resultado: cria variáveis:
#   PREFIXO_key="value"
#   PREFIXO_key2="value2 com espaços"
adm_read_kv_file() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_read_kv_file requer 2 argumentos: ARQUIVO PREFIXO"
        return 1
    fi

    local file="$1"
    local prefix="$2"

    if [ ! -f "$file" ]; then
        adm_log_error "adm_read_kv_file: arquivo não encontrado: $file"
        return 1
    fi

    if [ -z "$prefix" ]; then
        adm_log_error "adm_read_kv_file: PREFIXO não pode ser vazio."
        return 1
    fi

    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        # Remove espaços nas pontas
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Pula linhas vazias e comentários
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
        esac

        # Separa em key=val (primeira ocorrência de '=')
        case "$line" in
            *=*)
                key="${line%%=*}"
                val="${line#*=}"
                ;;
            *)
                adm_log_warn "adm_read_kv_file: linha inválida em '$file': $line"
                continue
                ;;
        esac

        # Remove espaços extras da chave
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        # Remove espaços extras do valor
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"

        # Valida chave (apenas letras, números e underscore)
        case "$key" in
            ''|*[!A-Za-z0-9_]*)
                adm_log_warn "adm_read_kv_file: chave inválida em '$file': '$key'"
                continue
                ;;
        esac

        # Monta nome final da variável
        local varname="${prefix}${key}"

        # Usa printf e eval de forma controlada
        # shellcheck disable=SC2086,SC2163
        eval "$varname=\"\$val\""
    done <"$file"

    return 0
}
###############################################################################
# Inicialização automática
###############################################################################
adm_core_init() {
    adm_core_init_paths
}
# Chamada imediata ao carregar o arquivo
adm_core_init
