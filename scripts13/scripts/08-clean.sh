#!/usr/bin/env bash
# 08-clean.sh - Limpeza inteligente do sistema ADM e auto-teste
#
# Limpa:
#   - builds antigos / órfãos
#   - sources órfãos
#   - pacotes antigos (mantém N versões)
#   - logs antigos
#   - locks e temporários
# E faz auto-teste do sistema (scripts, diretórios, DB, ferramentas básicas).
###############################################################################
# Detecção de modo (CLI vs sourced)
###############################################################################

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ADM_CLEAN_CLI_MODE=1
else
    ADM_CLEAN_CLI_MODE=0
fi

# Carrega env/lib se ainda não foram carregados
if [[ -z "${ADM_ENV_LOADED:-}" ]]; then
    if [[ -f /usr/src/adm/scripts/01-env.sh ]]; then
        # shellcheck disable=SC1091
        . /usr/src/adm/scripts/01-env.sh
    else
        echo "ERRO: 01-env.sh não encontrado em /usr/src/adm/scripts." >&2
        exit 1
    fi
fi

if [[ -z "${ADM_LIB_LOADED:-}" ]]; then
    if [[ -f /usr/src/adm/scripts/02-lib.sh ]]; then
        # shellcheck disable=SC1091
        . /usr/src/adm/scripts/02-lib.sh
    else
        echo "ERRO: 02-lib.sh não encontrado em /usr/src/adm/scripts." >&2
        exit 1
    fi
fi
###############################################################################
# 1. Configuração / defaults
###############################################################################
# Modo:
#   full   - tudo (padrão)
#   cache  - sources + pkg cache
#   logs   - só logs
#   cross  - limpeza orientada à cross-toolchain (usado por 06-cross-toolchain)
#   quick  - limpeza leve + auto-teste
ADM_CLEAN_MODE="full"

# Se 1, não remove realmente nada, só mostra o que faria
ADM_CLEAN_DRY_RUN=0

# Manter no mínimo N versões por pacote no cache
ADM_CLEAN_KEEP_VERSIONS_PER_PKG=2

# Apagar builds mais antigos que N dias (0 = desativa, não apaga por idade)
ADM_CLEAN_BUILD_MAX_AGE_DAYS=14

# Apagar logs mais antigos que N dias (0 = desativa)
ADM_CLEAN_LOG_MAX_AGE_DAYS=30

# Diretório de locks
ADM_LOCK_DIR="${ADM_LOCK_DIR:-${ADM_ROOT}/locks}"

###############################################################################
# 2. Helpers genéricos
###############################################################################

adm_clean_rm() {
    # rm com suporte a dry-run
    local path="$1"
    if [[ "$ADM_CLEAN_DRY_RUN" -eq 1 ]]; then
        adm_info "[DRY-RUN] rm -rf -- '${path}'"
        return 0
    fi
    rm -rf -- "$path" 2>/dev/null || adm_warn "Falha ao remover '${path}'."
}

adm_clean_unlink() {
    local path="$1"
    if [[ "$ADM_CLEAN_DRY_RUN" -eq 1 ]]; then
        adm_info "[DRY-RUN] rm -f -- '${path}'"
        return 0
    fi
    rm -f -- "$path" 2>/dev/null || adm_warn "Falha ao remover arquivo '${path}'."
}

adm_clean_is_older_than_days() {
    # Uso: adm_clean_is_older_than_days <path> <dias> ; retorna 0 se mais velho
    local path="$1"
    local days="$2"

    [[ "$days" -le 0 ]] && return 1
    [[ ! -e "$path" ]] && return 1

    # -mtime +N: mais que N dias
    find "$path" -maxdepth 0 -mtime +"$days" >/dev/null 2>&1
}

###############################################################################
# 3. Limpeza de diretórios de build
###############################################################################

adm_clean_builds() {
    local d

    [[ -d "${ADM_BUILD}" ]] || return 0

    adm_info "Limpando diretórios de build em '${ADM_BUILD}' (age>${ADM_CLEAN_BUILD_MAX_AGE_DAYS}d, órfãos/temporários)."

    # 1) builds sem .adm-source-manifest → lixo/antigo/incompleto
    while IFS= read -r -d '' d; do
        if [[ ! -f "${d}/.adm-source-manifest" ]]; then
            adm_info "Build sem manifesto detectado: '${d}' (será removido)."
            adm_clean_rm "$d"
        fi
    done < <(find "${ADM_BUILD}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

    # 2) builds antigos com manifesto
    if [[ "$ADM_CLEAN_BUILD_MAX_AGE_DAYS" -gt 0 ]]; then
        while IFS= read -r -d '' d; do
            if [[ -f "${d}/.adm-source-manifest" ]] && adm_clean_is_older_than_days "$d" "$ADM_CLEAN_BUILD_MAX_AGE_DAYS"; then
                adm_info "Build antigo (>${ADM_CLEAN_BUILD_MAX_AGE_DAYS}d) detectado: '${d}' (será removido)."
                adm_clean_rm "$d"
            fi
        done < <(find "${ADM_BUILD}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
    fi
}

###############################################################################
# 4. Limpeza de sources órfãos
###############################################################################

adm_clean_sources() {
    [[ -d "${ADM_SOURCES}" ]] || return 0

    adm_info "Limpando sources órfãos em '${ADM_SOURCES}'."

    # Build lista de nomes de source referenciados nos metafiles
    local tmp_ref tmp_file
    tmp_ref="$(mktemp "${ADM_ROOT}/.clean-sources-ref-XXXXXX")" || return 1
    tmp_file="$(mktemp "${ADM_ROOT}/.clean-sources-all-XXXXXX")" || { rm -f "$tmp_ref"; return 1; }

    # 1) Lista todo conteúdo de SOURCES
    find "${ADM_SOURCES}" -mindepth 1 -maxdepth 1 -print > "$tmp_file" 2>/dev/null || true

    # 2) Varre todos os metafiles e coleta nomes base usados em sources
    if [[ -d "${ADM_REPO}" ]]; then
        while IFS= read -r -d '' mf; do
            adm_meta_load "$mf" || continue
            local -a srcs
            adm_meta_get_sources_array srcs
            local s base
            for s in "${srcs[@]}"; do
                [[ -z "$s" ]] && continue
                # só se for URL/arquivo, ignora git/rsync/dir locais
                if [[ "$s" =~ ^(https?|ftp):// ]]; then
                    base="$(basename "$s")"
                    echo "${ADM_SOURCES}/${base}" >> "$tmp_ref"
                fi
            done
        done < <(find "${ADM_REPO}" -type f -name "metafile" -print0 2>/dev/null || true)
    fi

    # Normaliza listas (sort/uniq)
    sort -u -o "$tmp_ref" "$tmp_ref" 2>/dev/null || true
    sort -u -o "$tmp_file" "$tmp_file" 2>/dev/null || true

    # 3) Para cada arquivo real em SOURCES, se não estiver em ref → órfão
    local path
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        if ! grep -qx "$path" "$tmp_ref" 2>/dev/null; then
            adm_info "Source órfão detectado: '${path}' (será removido)."
            adm_clean_rm "$path"
        fi
    done < "$tmp_file"

    rm -f "$tmp_ref" "$tmp_file" 2>/dev/null || true
}

###############################################################################
# 5. Limpeza de logs antigos
###############################################################################

adm_clean_logs() {
    [[ -d "${ADM_LOGS}" ]] || return 0

    if [[ "$ADM_CLEAN_LOG_MAX_AGE_DAYS" -le 0 ]]; then
        adm_info "Limpeza de logs por idade desativada (ADM_CLEAN_LOG_MAX_AGE_DAYS<=0)."
        return 0
    fi

    adm_info "Limpando logs em '${ADM_LOGS}' com mais de ${ADM_CLEAN_LOG_MAX_AGE_DAYS} dias."

    local f
    while IFS= read -r -d '' f; do
        if adm_clean_is_older_than_days "$f" "$ADM_CLEAN_LOG_MAX_AGE_DAYS"; then
            adm_info "Log antigo: '${f}' (será removido)."
            adm_clean_unlink "$f"
        fi
    done < <(find "${ADM_LOGS}" -type f -print0 2>/dev/null || true)
}

###############################################################################
# 6. Limpeza de pacotes antigos no cache
###############################################################################

adm_clean_pkg_cache() {
    [[ -d "${ADM_PKG}" ]] || return 0

    adm_info "Limpando cache de pacotes em '${ADM_PKG}', mantendo ${ADM_CLEAN_KEEP_VERSIONS_PER_PKG} versão(ões) por pacote."

    # Vamos agrupar por "nome" (antes do primeiro '-<versão>-<profile>-<libc>.tar.*')
    local f base name key
    declare -A pkg_files

    while IFS= read -r -d '' f; do
        base="$(basename "$f")"
        # exemplo: foo-1.2.3-normal-glibc.tar.xz
        # strip extensão
        local noext="${base%.tar.zst}"
        noext="${noext%.tar.xz}"

        # heurística: "nome-versao-resto"
        # pegamos tudo até versão inclusa como "key completo" (porque diferentes profiles/libc contam como entradas distintas)
        key="$noext"
        pkg_files["$key"]+="${f}"$'\n'
    done < <(find "${ADM_PKG}" -maxdepth 1 -type f \( -name "*.tar.zst" -o -name "*.tar.xz" \) -print0 2>/dev/null || true)

    local list count idx
    for key in "${!pkg_files[@]}"; do
        list="${pkg_files[$key]}"
        # ordena por mtime (mais recente por último)
        mapfile -t _arr < <(printf '%s\n' "$list" | sed '/^$/d' | xargs -r -I{} stat -c '%Y %n' "{}" 2>/dev/null | sort -n | awk '{ $1=""; sub(/^ /,""); print }')
        count="${#_arr[@]}"

        if (( count <= ADM_CLEAN_KEEP_VERSIONS_PER_PKG )); then
            continue
        fi

        local to_delete=$((count - ADM_CLEAN_KEEP_VERSIONS_PER_PKG))
        for (( idx=0; idx<to_delete; idx++ )); do
            f="${_arr[idx]}"
            adm_info "Pacote antigo de '${key}': '${f}' (será removido)."
            adm_clean_unlink "$f"
        done
    done
}

###############################################################################
# 7. Limpeza de locks e arquivos temporários
###############################################################################

adm_clean_locks() {
    [[ -d "${ADM_LOCK_DIR}" ]] || return 0

    adm_info "Limpando locks antigos em '${ADM_LOCK_DIR}'."

    local d
    while IFS= read -r -d '' d; do
        # se não há PID ou PID morto, remove
        local pidfile="${d}/pid" pid
        if [[ -f "$pidfile" ]]; then
            pid="$(cat "$pidfile" 2>/dev/null || echo "")"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                adm_debug "Lock '${d}' ainda usado pelo PID=${pid}; não removendo."
                continue
            fi
        fi
        adm_info "Lock obsoleto: '${d}' (será removido)."
        adm_clean_rm "$d"
    done < <(find "${ADM_LOCK_DIR}" -mindepth 1 -maxdepth 1 -type d -name "*.lock" -print0 2>/dev/null || true)
}

adm_clean_temp_files() {
    adm_info "Limpando arquivos temporários conhecidos do ADM."

    # padrões de temp criados pelos scripts
    local pattern
    for pattern in \
        "${ADM_ROOT}/.install-files-"* \
        "${ADM_ROOT}/.clean-sources-"* \
        "${ADM_ROOT}/.clean-sources-ref-"* \
        "${ADM_ROOT}/.clean-sources-all-"* \
        "${ADM_ROOT}/.cross-*" ; do

        for f in $pattern; do
            [[ -e "$f" ]] || continue
            adm_info "Temp obsoleto: '${f}' (será removido)."
            adm_clean_unlink "$f"
        done
    done
}

###############################################################################
# 8. Auto-teste do sistema ADM
###############################################################################

adm_clean_self_test() {
    adm_info "Executando auto-teste do sistema ADM."

    local ok=1

    # 1) Verificar diretórios base
    if ! adm_ensure_directories; then
        adm_error "adm_ensure_directories falhou; estrutura básica de diretórios está quebrada."
        adm_info  "Sugestão: verifique permissões em '${ADM_ROOT}' e subdiretórios; recrie manualmente se necessário."
        ok=0
    fi

    # 2) Verificar scripts principais
    local script
    local required_scripts=(
        "01-env.sh"
        "02-lib.sh"
        "03-detect.sh"
        "04-build-pkg.sh"
        "05-install-pkg.sh"
        "06-cross-toolchain.sh"
        "07-remove-pkg.sh"
        "08-clean.sh"
        "09-update-pkg.sh"
        "10-upgrade-pkg.sh"
        "adm"
    )

    for script in "${required_scripts[@]}"; do
        if [[ ! -x "${ADM_SCRIPTS}/${script}" ]]; then
            if [[ -f "${ADM_SCRIPTS}/${script}" ]]; then
                adm_warn "Script '${ADM_SCRIPTS}/${script}' não é executável."
                adm_info "Sugestão: rode 'chmod +x ${ADM_SCRIPTS}/${script}'."
            else
                adm_error "Script obrigatório ausente: '${ADM_SCRIPTS}/${script}'."
                adm_info "Sugestão: recoloque o arquivo '${script}' em '${ADM_SCRIPTS}' a partir do seu repositório de configuração."
            fi
            ok=0
        fi
    done

    # 3) Verificar ferramentas externas críticas
    local tool
    local tools_required=(tar xz)
    for tool in "${tools_required[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            adm_error "Ferramenta obrigatória ausente: '${tool}'."
            adm_info  "Sugestão: instale '${tool}' no sistema host antes de continuar."
            ok=0
        fi
    done

    # 4) Verificar consistência simples do DB de pacotes
    if [[ -d "${ADM_DB_PKG}" ]]; then
        local f line
        for f in "${ADM_DB_PKG}"/*.installed; do
            [[ -e "$f" ]] || continue
            if ! grep -q '^name=' "$f" 2>/dev/null; then
                adm_warn "Registro de pacote suspeito (sem 'name='): '${f}'."
                adm_info "Sugestão: inspecione o arquivo e corrija/remova manualmente."
                ok=0
            fi
        done
    fi

    if [[ "$ok" -eq 1 ]]; then
        adm_info "Auto-teste concluído: sistema ADM parece consistente."
    else
        adm_warn "Auto-teste concluiu que existem problemas no sistema ADM."
        adm_info "Sugestão geral: corrija os itens acima, e depois rode novamente '08-clean.sh --mode quick' para validar."
    fi

    return "$ok"
}

###############################################################################
# 9. Pipelines por modo
###############################################################################

adm_clean_run_full() {
    adm_clean_builds
    adm_clean_sources
    adm_clean_pkg_cache
    adm_clean_logs
    adm_clean_locks
    adm_clean_temp_files
    adm_clean_self_test
}

adm_clean_run_cache() {
    adm_clean_builds
    adm_clean_sources
    adm_clean_pkg_cache
}

adm_clean_run_logs() {
    adm_clean_logs
}

adm_clean_run_cross() {
    # Modo usado por 06-cross-toolchain – foca em coisas que atrapalham cross
    adm_info "Modo cross: limpeza mais focada em builds e caches relacionados ao toolchain."
    adm_clean_builds
    adm_clean_pkg_cache
    adm_clean_temp_files
    adm_clean_self_test
}

adm_clean_run_quick() {
    adm_clean_temp_files
    adm_clean_locks
    adm_clean_self_test
}

###############################################################################
# 10. CLI
###############################################################################

adm_clean_usage() {
    cat <<EOF
Uso: 08-clean.sh [opções]

Opções:
  --mode <m>     - modo de limpeza:
                     full   : tudo (builds, sources, cache, logs, locks, temp, auto-teste) [padrão]
                     cache  : builds + sources + cache de pacotes
                     logs   : apenas logs
                     cross  : limpeza focada em cross-toolchain (usado por 06-cross-toolchain)
                     quick  : limpeza leve + auto-teste
  --dry-run      - não remove nada, apenas mostra o que faria
  --keep <N>     - manter N versões por pacote no cache (default: ${ADM_CLEAN_KEEP_VERSIONS_PER_PKG})
  --build-age <D>- remover builds com mais de D dias (0 = desativado, default: ${ADM_CLEAN_BUILD_MAX_AGE_DAYS})
  --log-age <D>  - remover logs com mais de D dias (0 = desativado, default: ${ADM_CLEAN_LOG_MAX_AGE_DAYS})
  -h, --help     - mostra esta ajuda

Exemplos:
  08-clean.sh
  08-clean.sh --mode cache --keep 1
  08-clean.sh --mode cross
  08-clean.sh --dry-run --mode full
EOF
}

adm_clean_main() {
    adm_enable_strict_mode

    local next_is_mode=0 next_is_keep=0 next_is_bage=0 next_is_lage=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                next_is_mode=1; shift; continue ;;
            --dry-run)
                ADM_CLEAN_DRY_RUN=1; shift ;;
            --keep)
                next_is_keep=1; shift; continue ;;
            --build-age)
                next_is_bage=1; shift; continue ;;
            --log-age)
                next_is_lage=1; shift; continue ;;
            -h|--help)
                adm_clean_usage
                exit 0
                ;;
            *)
                if [[ $next_is_mode -eq 1 ]]; then
                    ADM_CLEAN_MODE="$1"
                    next_is_mode=0
                    shift
                    continue
                elif [[ $next_is_keep -eq 1 ]]; then
                    ADM_CLEAN_KEEP_VERSIONS_PER_PKG="$1"
                    next_is_keep=0
                    shift
                    continue
                elif [[ $next_is_bage -eq 1 ]]; then
                    ADM_CLEAN_BUILD_MAX_AGE_DAYS="$1"
                    next_is_bage=0
                    shift
                    continue
                elif [[ $next_is_lage -eq 1 ]]; then
                    ADM_CLEAN_LOG_MAX_AGE_DAYS="$1"
                    next_is_lage=0
                    shift
                    continue
                else
                    adm_error "Argumento desconhecido: '$1'"
                    adm_clean_usage
                    exit 1
                fi
                ;;
        esac
    done

    adm_init_log "clean-${ADM_CLEAN_MODE}"

    adm_info "Iniciando 08-clean.sh (modo='${ADM_CLEAN_MODE}', dry-run=${ADM_CLEAN_DRY_RUN})."

    case "$ADM_CLEAN_MODE" in
        full)  adm_clean_run_full  ;;
        cache) adm_clean_run_cache ;;
        logs)  adm_clean_run_logs  ;;
        cross) adm_clean_run_cross ;;
        quick) adm_clean_run_quick ;;
        *)
            adm_error "Modo desconhecido: '${ADM_CLEAN_MODE}'"
            adm_clean_usage
            exit 1
            ;;
    esac

    adm_info "08-clean.sh concluído (modo='${ADM_CLEAN_MODE}')."
}

if [[ "$ADM_CLEAN_CLI_MODE" -eq 1 ]]; then
    adm_clean_main "$@"
fi
