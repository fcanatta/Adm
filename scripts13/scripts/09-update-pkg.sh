#!/usr/bin/env bash
# 09-update-pkg.sh
# - Descobre a versão estável mais recente no upstream (melhor esforço)
# - Cria metafile de update em: ${ADM_UPDATES}/<programa>/metafile
# - Verifica dependências (run/build/opt) e cria metafiles de update para elas também
###############################################################################
# Detecção de modo (CLI vs sourced)
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ADM_UPDATE_CLI_MODE=1
else
    ADM_UPDATE_CLI_MODE=0
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
# 1. Helpers de metafile / versão / paths
###############################################################################

adm_update_find_metafile_for_pkg() {
    # Uso: adm_update_find_metafile_for_pkg <nome>
    local name="$1"
    local f

    # Reutiliza buscadores existentes se disponíveis
    if declare -F adm_build_find_metafile_for_pkg >/dev/null 2>&1; then
        adm_build_find_metafile_for_pkg "$name" && return 0
    fi
    if declare -F adm_detect_find_metafile_for_pkg >/dev/null 2>&1; then
        adm_detect_find_metafile_for_pkg "$name" && return 0
    fi

    while IFS= read -r -d '' f; do
        if [[ "$(basename "$(dirname "$f")")" == "$name" ]]; then
            echo "$f"
            return 0
        fi
    done < <(find "${ADM_REPO}" -maxdepth 3 -type f -name "metafile" -print0 2>/dev/null || true)

    return 1
}

adm_update_is_newer_version() {
    # Uso: adm_update_is_newer_version <current> <candidate>
    # Retorna 0 se candidate > current (usando sort -V), 1 caso contrário.
    local cur="$1"
    local cand="$2"

    [[ -z "$cand" ]] && return 1
    [[ "$cand" == "$cur" ]] && return 1

    # sort -V lida bem com versões tipo 1.2.3, 1.2.3rc1 etc
    local last
    last="$(printf '%s\n' "$cur" "$cand" | sort -V | tail -n1)"
    [[ "$last" == "$cand" && "$last" != "$cur" ]]
}

adm_update_updates_path_for_pkg() {
    local name="$1"
    echo "${ADM_UPDATES}/${name}/metafile"
}

###############################################################################
# 2. Fetch de listing de upstream (melhor esforço)
###############################################################################

adm_update_fetch_url_to_stdout() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -L --compressed -s "$url" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O - "$url" || return 1
    else
        adm_error "Nem curl nem wget disponíveis para acessar '$url'."
        return 1
    fi
}

###############################################################################
# 3. Detecção de versão mais nova a partir de source URL
###############################################################################

adm_update_detect_latest_from_source_url() {
    # Uso: adm_update_detect_latest_from_source_url <url>
    # Saída: ecoa a versão detectada ou vazio se não conseguir
    local url="$1"

    # Só faz sentido para http(s)/ftp
    if ! [[ "$url" =~ ^https?:// || "$url" =~ ^ftp:// ]]; then
        echo ""
        return 0
    fi

    local name="${ADM_META_name}"
    local current_ver="${ADM_META_version}"

    # Base: tira o nome do arquivo
    local base_url file
    file="$(basename "$url")"
    base_url="${url%/*}/"

    adm_info "Consultando upstream em '${base_url}' para '${name}' (versão atual: ${current_ver})."

    local html
    html="$(adm_update_fetch_url_to_stdout "$base_url" 2>/dev/null)" || {
        adm_warn "Falha ao obter listing de '${base_url}'."
        echo ""
        return 0
    }

    # 1) Padrão clássico: name-versao.tar.*
    # Captura matches tipo: name-1.2.3.tar.xz
    local candidates
    candidates="$(printf '%s\n' "$html" | grep -Eo "${name}-[0-9][0-9A-Za-z._-]*\.tar\.(gz|bz2|xz|zst|bz|lz|lzma|Z)" | sort -u || true)"

    # 2) Padrão v1.2.3.tar.* (projetos que usam 'v' prefixado)
    local v_candidates
    v_candidates="$(printf '%s\n' "$html" | grep -Eo "v[0-9][0-9A-Za-z._-]*\.tar\.(gz|bz2|xz|zst|bz|lz|lzma|Z)" | sort -u || true)"

    local vers_list=""

    # Extrai versões de candidates tipo name-1.2.3.tar.xz
    local line ver
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        line="${line##*/}"               # tira path
        line="${line%%.tar.*}"           # tira extensão
        ver="${line#${name}-}"           # tira prefixo "name-"
        [[ -z "$ver" || "$ver" == "$line" ]] && continue
        vers_list+="${ver}"$'\n'
    done <<< "$candidates"

    # Extrai versões de v_candidates tipo v1.2.3.tar.xz
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        line="${line##*/}"
        line="${line%%.tar.*}"
        ver="${line#v}"                  # tira 'v'
        [[ -z "$ver" || "$ver" == "$line" ]] && continue
        vers_list+="${ver}"$'\n'
    done <<< "$v_candidates"

    # Se nada encontrado, desiste
    if [[ -z "$vers_list" ]]; then
        adm_warn "Não foi possível extrair versões de listing em '${base_url}'."
        echo ""
        return 0
    fi

    # Escolhe a maior versão com sort -V
    local latest
    latest="$(printf '%s\n' "$vers_list" | sed '/^$/d' | sort -V | tail -n1)"

    if [[ -z "$latest" ]]; then
        echo ""
        return 0
    fi

    echo "$latest"
}

###############################################################################
# 4. Detecção de versão mais nova (upstream geral)
###############################################################################

adm_update_detect_latest_version() {
    # Tenta todas as sources até achar uma versão > current
    local -a srcs
    adm_meta_get_sources_array srcs

    local current_ver="${ADM_META_version}"
    local best_ver="$current_ver"
    local s candidate

    for s in "${srcs[@]}"; do
        [[ -z "$s" ]] && continue
        candidate="$(adm_update_detect_latest_from_source_url "$s")"
        [[ -z "$candidate" ]] && continue

        if adm_update_is_newer_version "$best_ver" "$candidate"; then
            best_ver="$candidate"
        fi
    done

    if [[ "$best_ver" == "$current_ver" ]]; then
        # Nada melhor encontrado
        echo ""
        return 0
    fi

    echo "$best_ver"
}

###############################################################################
# 5. Construção de novo metafile de update
###############################################################################

adm_update_build_sources_for_new_version() {
    # Uso: adm_update_build_sources_for_new_version <new_ver>
    # Saída: ecoa CSV de sources com versão atual substituída pela nova onde possível
    local new_ver="$1"
    local old_ver="${ADM_META_version}"

    local -a srcs
    adm_meta_get_sources_array srcs

    local out=()
    local s new_s
    for s in "${srcs[@]}"; do
        [[ -z "$s" ]] && continue
        if [[ "$s" == *"$old_ver"* ]]; then
            new_s="${s//$old_ver/$new_ver}"
            out+=("$new_s")
        else
            # se não tem versão embutida, mantém como está
            out+=("$s")
        fi
    done

    local IFS=','
    echo "${out[*]}"
}

adm_update_write_metafile() {
    # Uso: adm_update_write_metafile <new_ver> <new_sources_csv> <dest_path>
    local new_ver="$1"
    local new_sources="$2"
    local dest="$3"

    local dir
    dir="$(dirname "$dest")"
    mkdir -p "$dir" || {
        adm_error "Não foi possível criar diretório de updates '${dir}'."
        return 1
    }

    # num_builds reseta para 0; hashes ficam vazios (serão preenchidos após build/detect)
    cat > "$dest" <<EOF
name=${ADM_META_name}
version=${new_ver}
category=${ADM_META_category}
run_deps=${ADM_META_run_deps}
build_deps=${ADM_META_build_deps}
opt_deps=${ADM_META_opt_deps}
num_builds=0
description=${ADM_META_description}
homepage=${ADM_META_homepage}
maintainer=${ADM_META_maintainer}
sha256sums=
md5sum=
sources=${new_sources}
EOF

    adm_info "Metafile de update criado em: ${dest}"
}

###############################################################################
# 6. Update de UM pacote (sem deps)
###############################################################################

adm_update_one_pkg_no_deps() {
    local metafile="$1"

    adm_init_log "update-$(basename "$metafile")"
    adm_info "Iniciando 09-update-pkg para metafile: ${metafile}"

    adm_meta_load "$metafile" || return 1

    local current_ver new_ver
    current_ver="${ADM_META_version}"

    adm_info "Versão atual de '${ADM_META_name}' é '${current_ver}'. Buscando nova versão estável..."

    new_ver="$(adm_update_detect_latest_version)"

    if [[ -z "$new_ver" ]]; then
        adm_info "Nenhuma versão mais nova encontrada para '${ADM_META_name}'. Parece já estar na última versão conhecida."
        return 0
    fi

    adm_info "Nova versão detectada para '${ADM_META_name}': ${new_ver}"

    if ! adm_update_is_newer_version "$current_ver" "$new_ver"; then
        adm_info "Versão detectada '${new_ver}' não é maior que a atual '${current_ver}'. Nada a fazer."
        return 0
    fi

    local new_sources
    new_sources="$(adm_update_build_sources_for_new_version "$new_ver")"

    local dest
    dest="$(adm_update_updates_path_for_pkg "${ADM_META_name}")"

    adm_update_write_metafile "$new_ver" "$new_sources" "$dest" || return 1

    adm_info "Update de '${ADM_META_name}' preparado (metafile em updates)."
}

###############################################################################
# 7. Update de dependências (run/build/opt)
###############################################################################

adm_update_unique_dep_list() {
    # Junta e de-duplica deps de run/build/opt
    local all=""
    [[ -n "${ADM_META_run_deps}"   ]] && all+="${ADM_META_run_deps},"
    [[ -n "${ADM_META_build_deps}" ]] && all+="${ADM_META_build_deps},"
    [[ -n "${ADM_META_opt_deps}"   ]] && all+="${ADM_META_opt_deps},"

    all="${all%,}"  # tira vírgula final

    local -a arr
    local IFS=','
    read -r -a arr <<< "$all"

    # de-dup simples
    declare -A seen=()
    local out=()
    local d
    for d in "${arr[@]}"; do
        [[ -z "$d" ]] && continue
        if [[ -z "${seen[$d]:-}" ]]; then
            seen["$d"]=1
            out+=("$d")
        fi
    done

    printf '%s\n' "${out[@]}"
}

adm_update_dep_pkg() {
    local dep="$1"

    [[ -z "$dep" ]] && return 0

    local meta_dep
    meta_dep="$(adm_update_find_metafile_for_pkg "$dep" || true)"
    if [[ -z "$meta_dep" ]]; then
        adm_warn "Metafile não encontrado para dependência '${dep}'; não será atualizado."
        return 0
    fi

    adm_info "Atualizando dependência '${dep}' via 09-update-pkg (sem recursão de deps de deps)."

    # Carrega metadata do dep
    adm_meta_load "$meta_dep" || {
        adm_warn "Falha ao carregar metafile de '${dep}'."
        return 0
    }

    local current_ver new_ver
    current_ver="${ADM_META_version}"

    new_ver="$(adm_update_detect_latest_version)"

    if [[ -z "$new_ver" ]]; then
        adm_info "Dependência '${dep}' já parece estar na última versão conhecida (${current_ver})."
        return 0
    fi

    if ! adm_update_is_newer_version "$current_ver" "$new_ver"; then
        adm_info "Dependência '${dep}': versão nova '${new_ver}' não é maior que '${current_ver}'."
        return 0
    fi

    local new_sources
    new_sources="$(adm_update_build_sources_for_new_version "$new_ver")"
    local dest
    dest="$(adm_update_updates_path_for_pkg "${ADM_META_name}")"

    adm_update_write_metafile "$new_ver" "$new_sources" "$dest" || return 1

    adm_info "Update preparado para dependência '${ADM_META_name}' -> versão ${new_ver}."
}

adm_update_all_deps() {
    local deps
    deps="$(adm_update_unique_dep_list)"

    if [[ -z "$deps" ]]; then
        adm_info "Pacote '${ADM_META_name}' não possui dependências para atualizar."
        return 0
    fi

    local dep
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        adm_run_with_spinner "Verificando update para dependência '${dep}'..." \
            adm_update_dep_pkg "$dep" || adm_warn "Falha ao atualizar dependência '${dep}'."
    done <<< "$deps"
}

###############################################################################
# 8. Pipeline principal: pacote + deps
###############################################################################

adm_update_pipeline() {
    local metafile="$1"
    local no_deps="$2"   # 0 = atualizar deps também; 1 = não

    adm_init_log "update-$(basename "$metafile")"
    adm_info "Pipeline 09-update-pkg para metafile: ${metafile}"

    # Carrega uma vez (será recarregado em funções de dep quando necessário)
    adm_meta_load "$metafile" || return 1

    # Primeiro o pacote principal
    adm_update_one_pkg_no_deps "$metafile" || return 1

    # Recarrega metafile "pai" (pois funções de dep podem ter sobrescrito ADM_META_* temporariamente)
    adm_meta_load "$metafile" || return 1

    # Agora as dependências
    if [[ "$no_deps" -eq 0 ]]; then
        adm_update_all_deps
    else
        adm_info "Atualização de dependências desabilitada (--no-deps)."
    fi

    adm_info "09-update-pkg concluído para '${ADM_META_name}'."
}

###############################################################################
# 9. CLI
###############################################################################

adm_update_usage() {
    cat <<EOF
Uso: 09-update-pkg.sh [opções] <pacote|caminho_metafile>

Opções:
  --no-deps   - NÃO verificar/gerar updates para dependências (apenas o pacote)
  -h, --help  - mostra esta ajuda

Comportamento:
  - Descobre a versão estável mais recente do pacote no upstream (melhor esforço),
    usando os 'sources=' e o 'name=' do metafile.
  - Se encontrar versão maior, cria:
        ${ADM_UPDATES}/<programa>/metafile
    com:
        - nova versão
        - num_builds=0
        - sha256sums/md5sum vazios
        - sources ajustados com a nova versão (quando possível)
  - Em seguida, faz o mesmo para todas as dependências (run_deps, build_deps, opt_deps),
    criando metafiles delas em ${ADM_UPDATES}/<dep>/metafile.

Exemplos:
  09-update-pkg.sh bash
  09-update-pkg.sh ${ADM_REPO}/sys/bash/metafile
  09-update-pkg.sh --no-deps bash
EOF
}

adm_update_main() {
    adm_enable_strict_mode

    local no_deps=0
    local arg=""
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-deps)
                no_deps=1
                shift
                ;;
            -h|--help)
                adm_update_usage
                exit 0
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    if [[ "${#args[@]}" -lt 1 ]]; then
        adm_update_usage
        exit 1
    fi

    arg="${args[0]}"

    local metafile=""
    if [[ -f "$arg" || -d "$arg" ]]; then
        if [[ -d "$arg" ]]; then
            metafile="${arg%/}/metafile"
        else
            metafile="$arg"
        fi
    else
        metafile="$(adm_update_find_metafile_for_pkg "$arg" || true)"
        if [[ -z "$metafile" ]]; then
            adm_error "Metafile não encontrado para pacote '$arg'."
            exit 1
        fi
    fi

    adm_update_pipeline "$metafile" "$no_deps"
}

if [[ "$ADM_UPDATE_CLI_MODE" -eq 1 ]]; then
    adm_update_main "$@"
fi
