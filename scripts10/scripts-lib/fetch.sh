#!/usr/bin/env bash
# lib/adm/fetch.sh
#
# Sistema de download de fontes do ADM:
#   - Cache em ADM_SOURCE_CACHE_DIR
#   - Suporte a múltiplos protocolos:
#       * http/https
#       * ftp
#       * rsync
#       * git (incluindo GitHub/GitLab)
#       * diretório/local (gera tarball opcional)
#   - Downloads múltiplos e em paralelo
#   - Verificação opcional de sha256
#   - Zero erros silenciosos: tudo relevante é logado.
#
# Este script fornece principalmente:
#
#   adm_fetch_url URL [DEST_HINT] [SHA256]
#       → Faz o download apenas dessa URL e imprime no stdout o caminho local
#
#   adm_fetch_sources PKG_ID SOURCES_CSV SHA256S_CSV
#       → Faz download de várias URLs em paralelo, usando ADM_FETCH_JOBS
#       → Retorna 0 se todas OK, !=0 se alguma falhar
#
# Onde:
#   PKG_ID       = string para logs, ex: "base/gcc"
#   SOURCES_CSV  = "url1,url2,url3"
#   SHA256S_CSV  = "sha1,sha2,sha3" (pode ser vazio ou ter menos itens)
#===============================================================================
# Proteção contra múltiplos loads
#===============================================================================
if [ -n "${ADM_FETCH_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
ADM_FETCH_LOADED=1
#===============================================================================
# Dependências: log + core
#===============================================================================
if ! command -v adm_log_info >/dev/null 2>&1; then
    # Fallback mínimo se log.sh ainda não foi carregado
    adm_log()       { printf '%s\n' "$*" >&2; }
    adm_log_info()  { adm_log "[INFO]  $*"; }
    adm_log_warn()  { adm_log "[WARN]  $*"; }
    adm_log_error() { adm_log "[ERROR] $*"; }
    adm_log_debug() { :; }
    adm_log_fetch() { adm_log "[FETCH] $*"; }
fi

if ! command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_log_error "fetch.sh requer core.sh (função adm_core_init_paths não encontrada)."
else
    adm_core_init_paths
fi

: "${ADM_SOURCE_CACHE_DIR:=${ADM_ROOT:-/usr/src/adm}/cache/sources}"
: "${ADM_FETCH_JOBS:=4}"   # número de downloads paralelos
# Garante diretório de cache
adm_mkdir_p "$ADM_SOURCE_CACHE_DIR" || adm_log_error "Falha ao criar ADM_SOURCE_CACHE_DIR: $ADM_SOURCE_CACHE_DIR"
#===============================================================================
# Helpers internos
#===============================================================================
# Verifica se temos curl ou wget
adm_fetch__have_downloader() {
    if command -v curl >/dev/null 2>&1; then
        printf 'curl\n'
        return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        printf 'wget\n'
        return 0
    fi
    adm_log_error "Nem 'curl' nem 'wget' encontrados; não é possível fazer downloads HTTP/FTP."
    return 1
}

# Normaliza string (remove espaços nas pontas)
adm_fetch__trim() {
    # Uso: adm_fetch__trim "  abc  " → imprime "abc"
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Gera um "hash curto" de uma string, se sha1sum estiver disponível.
adm_fetch__short_hash() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_fetch__short_hash requer 1 argumento."
        printf 'hash-erro'
        return 1
    fi
    local s="$1"
    if command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$s" | sha1sum 2>/dev/null | awk '{print substr($1,1,8)}'
    else
        # Fallback tosco: remove caracteres estranhos
        printf '%s' "$s" | tr -c 'A-Za-z0-9' '_' | cut -c1-16
    fi
}

# Deduz "nome base" para um URL
adm_fetch__safe_basename() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_fetch__safe_basename requer 1 argumento."
        printf 'source-unnamed'
        return 1
    fi
    local url="$1"
    local base="${url##*/}"

    if [ -z "$base" ] || [ "$base" = "." ] || [ "$base" = ".." ]; then
        base="source-$(adm_fetch__short_hash "$url")"
    fi

    printf '%s' "$base"
}

# Detecta tipo de fonte a partir do URL/caminho
# Possíveis retornos:
#   http, ftp, rsync, git, file, dir
adm_fetch__detect_type() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_fetch__detect_type requer 1 argumento."
        printf 'unknown'
        return 1
    fi
    local url="$1"

    case "$url" in
        git://*|ssh://*|git+http://*|git+https://*)
            printf 'git'
            return 0
            ;;
        http://*|https://*)
            # Pode ser git ou tarball; se terminar em .git, tratamos como git
            case "$url" in
                *.git)
                    printf 'git'
                    return 0
                    ;;
                *)
                    printf 'http'
                    return 0
                    ;;
            esac
            ;;
        ftp://*)
            printf 'ftp'
            return 0
            ;;
        rsync://*)
            printf 'rsync'
            return 0
            ;;
        file://*)
            # Caminho local
            printf 'file'
            return 0
            ;;
        *://*)
            # Algum protocolo desconhecido
            adm_log_warn "Protocolo possivelmente não suportado para URL: %s" "$url"
            printf 'unknown'
            return 0
            ;;
        *)
            # Sem "://": pode ser caminho local
            if [ -d "$url" ]; then
                printf 'dir'
                return 0
            elif [ -f "$url" ]; then
                printf 'file'
                return 0
            else
                # Pode ser caminho relativo ou algo bizarro; tratamos como file e deixamos falhar se não existir
                printf 'file'
                return 0
            fi
            ;;
    esac
}

# Verifica sha256 se esperado
adm_fetch__verify_sha256() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_fetch__verify_sha256 requer 2 argumentos: ARQUIVO SHA256"
        return 1
    fi
    local file="$1" expected="$2"

    if [ -z "$expected" ]; then
        # Nada a verificar
        return 0
    fi

    if [ ! -f "$file" ]; then
        adm_log_error "adm_fetch__verify_sha256: arquivo não encontrado: %s" "$file"
        return 1
    fi

    if ! command -v sha256sum >/dev/null 2>&1; then
        adm_log_warn "sha256sum não encontrado; não é possível verificar hash de: %s" "$file"
        return 0
    fi

    local got
    got="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')"
    if [ -z "$got" ]; then
        adm_log_error "Falha ao obter sha256 de: %s" "$file"
        return 1
    fi

    if [ "$got" != "$expected" ]; then
        adm_log_error "SHA256 incorreto para %s. Esperado=%s, Obtido=%s" "$file" "$expected" "$got"
        return 1
    fi

    adm_log_fetch "SHA256 OK para %s" "$file"
    return 0
}

#===============================================================================
# Backends de download
#===============================================================================

# HTTP/HTTPS/FTP (via curl ou wget)
adm_fetch__backend_http() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_fetch__backend_http requer 2 argumentos: URL DEST"
        return 1
    fi
    local url="$1" dest="$2"

    local dl
    dl="$(adm_fetch__have_downloader)" || return 1

    adm_log_fetch "Baixando (HTTP/FTP): %s → %s" "$url" "$dest"

    case "$dl" in
        curl)
            # -L segue redirects, --fail para erro em HTTP >= 400
            if ! curl -L --fail -o "$dest" "$url" 2>/dev/null; then
                adm_log_error "Falha ao baixar com curl: %s" "$url"
                rm -f "$dest" 2>/dev/null || :
                return 1
            fi
            ;;
        wget)
            if ! wget -O "$dest" "$url" >/dev/null 2>&1; then
                adm_log_error "Falha ao baixar com wget: %s" "$url"
                rm -f "$dest" 2>/dev/null || :
                return 1
            fi
            ;;
        *)
            adm_log_error "Downloader desconhecido: %s" "$dl"
            return 1
            ;;
    esac

    return 0
}

# RSYNC
adm_fetch__backend_rsync() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_fetch__backend_rsync requer 2 argumentos: URL DEST"
        return 1
    fi
    local url="$1" dest="$2"

    if ! command -v rsync >/dev/null 2>&1; then
        adm_log_error "rsync não encontrado; não é possível baixar: %s" "$url"
        return 1
    fi

    adm_log_fetch "Baixando (rsync): %s → %s" "$url" "$dest"
    if ! rsync -a --delete "$url" "$dest" >/dev/null 2>&1; then
        adm_log_error "Falha ao baixar via rsync: %s" "$url"
        return 1
    fi

    return 0
}

# GIT (clone/atualização em cache)
adm_fetch__backend_git() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_fetch__backend_git requer 2 argumentos: URL DEST_DIR"
        return 1
    fi
    local url="$1" dest_dir="$2"

    if ! command -v git >/dev/null 2>&1; then
        adm_log_error "git não encontrado; não é possível clonar: %s" "$url"
        return 1
    fi

    adm_mkdir_p "$(dirname "$dest_dir")" || {
        adm_log_error "Falha ao criar diretório pai de repositório git: %s" "$(dirname "$dest_dir")"
        return 1
    }

    if [ -d "$dest_dir/.git" ]; then
        adm_log_fetch "Atualizando repositório git em cache: %s" "$dest_dir"
        if ! git -C "$dest_dir" fetch --all --tags >/dev/null 2>&1; then
            adm_log_warn "Falha ao atualizar repositório git (usando estado existente): %s" "$dest_dir"
        fi
    else
        adm_log_fetch "Clonando repositório git: %s → %s" "$url" "$dest_dir"
        if ! git clone --depth 1 "$url" "$dest_dir" >/dev/null 2>&1; then
            adm_log_error "Falha ao clonar repositório git: %s" "$url"
            rm -rf "$dest_dir" 2>/dev/null || :
            return 1
        fi
    fi

    return 0
}

# FILE/DIR (local)
adm_fetch__backend_file() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_fetch__backend_file requer 2 argumentos: ORIGEM DEST"
        return 1
    fi
    local src="$1" dest="$2"

    # Remove prefixo file:// se presente
    case "$src" in
        file://*)
            src="${src#file://}"
            ;;
    esac

    if [ ! -e "$src" ]; then
        adm_log_error "Fonte local não encontrada: %s" "$src"
        return 1
    fi

    if [ -d "$src" ]; then
        # Diretório: criamos um tarball no dest
        adm_log_fetch "Empacotando diretório local: %s → %s" "$src" "$dest"
        if ! tar -C "$src" -cf "$dest" . 2>/dev/null; then
            adm_log_error "Falha ao empacotar diretório: %s" "$src"
            rm -f "$dest" 2>/dev/null || :
            return 1
        fi
    else
        # Arquivo: apenas copia
        adm_log_fetch "Copiando arquivo local: %s → %s" "$src" "$dest"
        if ! cp -f "$src" "$dest" 2>/dev/null; then
            adm_log_error "Falha ao copiar arquivo: %s" "$src"
            rm -f "$dest" 2>/dev/null || :
            return 1
        fi
    fi

    return 0
}

#===============================================================================
# Função pública: adm_fetch_url
#===============================================================================

# Uso:
#   adm_fetch_url URL [DEST_HINT] [SHA256]
#
# Saída:
#   caminho local do arquivo/checkout no stdout.
#
# Comportamento:
#   - Usa cache em ADM_SOURCE_CACHE_DIR
#   - Se arquivo já existir e SHA256 (se fornecido) bater, não baixa de novo.
adm_fetch_url() {
    if [ $# -lt 1 ] || [ $# -gt 3 ]; then
        adm_log_error "adm_fetch_url requer 1 a 3 argumentos: URL [DEST_HINT] [SHA256]"
        return 1
    fi

    local url="$1"
    local hint="${2:-}"
    local sha="${3:-}"

    url="$(adm_fetch__trim "$url")"
    hint="$(adm_fetch__trim "$hint")"
    sha="$(adm_fetch__trim "$sha")"

    if [ -z "$url" ]; then
        adm_log_error "adm_fetch_url: URL não pode ser vazia."
        return 1
    fi

    local type
    type="$(adm_fetch__detect_type "$url")" || type="unknown"

    local base dest path_in_cache
    case "$type" in
        http|ftp)
            base="${hint:-$(adm_fetch__safe_basename "$url")}"
            dest="$ADM_SOURCE_CACHE_DIR/$base"
            path_in_cache="$dest"
            ;;
        rsync)
            base="${hint:-$(adm_fetch__safe_basename "$url")}"
            # rsync geralmente trata como diretório
            dest="$ADM_SOURCE_CACHE_DIR/$base"
            path_in_cache="$dest"
            ;;
        git)
            base="${hint:-$(adm_fetch__safe_basename "$url")}"
            dest="$ADM_SOURCE_CACHE_DIR/git/$base"
            path_in_cache="$dest"
            ;;
        file|dir)
            base="${hint:-$(adm_fetch__safe_basename "$url")}"
            dest="$ADM_SOURCE_CACHE_DIR/$base"
            path_in_cache="$dest"
            ;;
        unknown)
            adm_log_warn "Tipo de fonte desconhecido para URL '%s'; tentando tratar como HTTP." "$url"
            base="${hint:-$(adm_fetch__safe_basename "$url")}"
            dest="$ADM_SOURCE_CACHE_DIR/$base"
            path_in_cache="$dest"
            type="http"
            ;;
    esac

    # Se já temos em cache, tentar apenas verificar hash (se fornecido)
    if [ -e "$path_in_cache" ] && [ -n "$sha" ]; then
        if adm_fetch__verify_sha256 "$path_in_cache" "$sha"; then
            adm_log_fetch "Fonte já presente em cache e verificada: %s" "$path_in_cache"
            printf '%s\n' "$path_in_cache"
            return 0
        else
            adm_log_warn "Cache existente para %s/%s não passou na verificação; refazendo download." "$url" "$path_in_cache"
        fi
    fi

    # Garante diretório pai
    adm_mkdir_p "$(dirname "$dest")" || {
        adm_log_error "Falha ao criar diretório de cache: %s" "$(dirname "$dest")"
        return 1
    }

    local rc=0
    case "$type" in
        http|ftp)
            adm_fetch__backend_http "$url" "$dest" || rc=$?
            ;;
        rsync)
            adm_fetch__backend_rsync "$url" "$dest" || rc=$?
            ;;
        git)
            adm_fetch__backend_git "$url" "$dest" || rc=$?
            ;;
        file|dir)
            adm_fetch__backend_file "$url" "$dest" || rc=$?
            ;;
        *)
            adm_log_error "Tipo de fonte não suportado: '%s' (URL=%s)" "$type" "$url"
            return 1
            ;;
    esac

    if [ $rc -ne 0 ]; then
        adm_log_error "Falha ao obter fonte: %s" "$url"
        return $rc
    fi

    # Verifica sha se fornecido (para tipos que geram arquivo único)
    case "$type" in
        http|ftp|file|dir)
            if ! adm_fetch__verify_sha256 "$dest" "$sha"; then
                adm_log_error "Falha na verificação de hash para: %s" "$dest"
                return 1
            fi
            ;;
        rsync|git)
            # Muito difícil definir um único arquivo para hashear; ignoramos sha.
            if [ -n "$sha" ]; then
                adm_log_warn "SHA256 fornecido para fonte rsync/git será ignorado (URL=%s)." "$url"
            fi
            ;;
    esac

    printf '%s\n' "$path_in_cache"
    return 0
}

#===============================================================================
# Função pública: adm_fetch_sources (múltiplos downloads em paralelo)
#===============================================================================

# Uso:
#   adm_fetch_sources PKG_ID SOURCES_CSV SHA256S_CSV
#
# Exemplo:
#   adm_fetch_sources "base/gcc" \
#       "url1,url2,url3" \
#       "sha1,sha2,sha3"
#
# - Faz os downloads em paralelo (até ADM_FETCH_JOBS jobs simultâneos).
# - Se não houver sha para alguma fonte (lista menor), essa não é verificada.
# - Retorna 0 se todas as fontes foram baixadas com sucesso, !=0 caso contrário.
adm_fetch_sources() {
    if [ $# -ne 3 ]; then
        adm_log_error "adm_fetch_sources requer 3 argumentos: PKG_ID SOURCES_CSV SHA256S_CSV"
        return 1
    fi

    local pkg_id="$1"
    local sources_csv="$2"
    local sha_csv="$3"

    sources_csv="$(adm_fetch__trim "$sources_csv")"
    sha_csv="$(adm_fetch__trim "$sha_csv")"

    if [ -z "$sources_csv" ]; then
        adm_log_error "adm_fetch_sources: SOURCES_CSV não pode ser vazio (pkg=%s)." "$pkg_id"
        return 1
    fi

    # Converte CSV em arrays
    local IFS=',' src sha
    local -a SOURCES=()
    local -a SHAS=()

    # SOURCES
    IFS=',' read -r -a SOURCES <<<"$sources_csv"
    # SHAS (pode estar vazio)
    if [ -n "$sha_csv" ]; then
        IFS=',' read -r -a SHAS <<<"$sha_csv"
    else
        SHAS=()
    fi

    local total="${#SOURCES[@]}"
    local i
    if [ "$total" -eq 0 ]; then
        adm_log_error "adm_fetch_sources: nenhuma fonte após parse do CSV (pkg=%s)." "$pkg_id"
        return 1
    fi

    adm_log_fetch "Iniciando download de %d fontes para %s (até %d em paralelo)..." "$total" "$pkg_id" "$ADM_FETCH_JOBS"

    # Controle simples de jobs
    local -a JOB_PIDS=()
    local -a JOB_DESC=()
    local job_count=0
    local active_jobs=0
    local max_jobs="$ADM_FETCH_JOBS"

    # Cria tmpdir para registros de erros (facilita debug)
    local tmpdir
    tmpdir="$(adm_tmpdir_create 'adm-fetch')" || {
        adm_log_error "Falha ao criar tmpdir para fetch de %s." "$pkg_id"
        return 1
    }

    for ((i=0; i<total; i++)); do
        src="$(adm_fetch__trim "${SOURCES[$i]}")"
        [ -z "$src" ] && continue

        if [ "$i" -lt "${#SHAS[@]}" ]; then
            sha="$(adm_fetch__trim "${SHAS[$i]}")"
        else
            sha=""
        fi

        # Gera "hint" com base no pkg_id + índice
        local hint
        hint="$(adm_fetch__safe_basename "$src")"
        hint="${pkg_id//\//-}-$hint"

        # Arquivo para registrar resultado
        local job_tag="job_$i"
        local job_err="$tmpdir/$job_tag.err"

        # Aguarda se há jobs demais
        while [ "$active_jobs" -ge "$max_jobs" ]; do
            local pid rc idx new_job_pids=() new_job_desc=()
            for idx in "${!JOB_PIDS[@]}"; do
                pid="${JOB_PIDS[$idx]}"
                if kill -0 "$pid" 2>/dev/null; then
                    # Ainda rodando
                    new_job_pids+=("$pid")
                    new_job_desc+=("${JOB_DESC[$idx]}")
                else
                    # Terminou, verifica rc
                    wait "$pid"
                    rc=$?
                    if [ $rc -ne 0 ]; then
                        adm_log_error "Download falhou (job=%s) para %s" "${JOB_DESC[$idx]}" "$pkg_id"
                    fi
                    active_jobs=$((active_jobs - 1))
                fi
            done
            JOB_PIDS=("${new_job_pids[@]}")
            JOB_DESC=("${new_job_desc[@]}")

            if [ "$active_jobs" -ge "$max_jobs" ]; then
                sleep 1
            fi
        done

        # Inicia job em background
        (
            local path
            path="$(adm_fetch_url "$src" "$hint" "$sha")" || {
                echo "RC=1" >"$job_err"
                exit 1
            }
            echo "RC=0 PATH=$path" >"$job_err"
        ) &
        local pid=$!
        JOB_PIDS+=("$pid")
        JOB_DESC+=("src#$i:$src")
        active_jobs=$((active_jobs + 1))
        job_count=$((job_count + 1))
    done

    # Espera todos os jobs terminarem
    local any_error=0
    local pid rc idx
    for idx in "${!JOB_PIDS[@]}"; do
        pid="${JOB_PIDS[$idx]}"
        wait "$pid"
        rc=$?
        if [ $rc -ne 0 ]; then
            adm_log_error "Job de download falhou (desc=%s) para %s" "${JOB_DESC[$idx]}" "$pkg_id"
            any_error=1
        fi
    done

    # Analisa arquivos de resultado
    local f line
    for f in "$tmpdir"/*.err; do
        [ -f "$f" ] || continue
        line="$(cat "$f" 2>/dev/null || echo '')"
        case "$line" in
            RC=0*)
                adm_log_debug "Download OK: %s" "$line"
                ;;
            RC=1*)
                adm_log_error "Erro registrado em job de download: %s" "$line"
                any_error=1
                ;;
        esac
    done

    # Limpa tmpdir
    adm_rm_rf_safe "$tmpdir" || adm_log_warn "Falha ao remover tmpdir de fetch: %s" "$tmpdir"

    if [ "$any_error" -ne 0 ]; then
        adm_log_error "Um ou mais downloads falharam para %s." "$pkg_id"
        return 1
    fi

    adm_log_fetch "Todos os downloads concluídos com sucesso para %s." "$pkg_id"
    return 0
}

#===============================================================================
# Inicialização
#===============================================================================

adm_fetch_init() {
    adm_log_debug "Subsistema de fetch inicializado (cache: %s, jobs=%s)." "$ADM_SOURCE_CACHE_DIR" "$ADM_FETCH_JOBS"
}

adm_fetch_init
