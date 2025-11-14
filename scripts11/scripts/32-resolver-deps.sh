#!/usr/bin/env bash
# 32-resolver-deps.sh
# Resolver de dependências do ADM.
#
# Usa campos do metafile:
#   run_deps=dep1,dep2
#   build_deps=depA,depB
#   opt_deps=depX,depY
#
# Formato de cada dependência:
#   - "categoria/programa" (ex: "dev/gcc")
#   - "programa"           (ex: "gcc")  -> categoria detectada automaticamente
#
# Principais funções públicas:
#
#   adm_deps_resolve_for_pkg <categoria> <nome> <modo>
#       -> modo: build | run | all
#       -> imprime em stdout, um por linha: "categoria nome" em ordem topológica
#
#   adm_deps_resolve_from_token <token> <modo>
#       -> token pode ser "cat/pkg" ou só "pkg"; resolve e chama adm_deps_resolve_for_pkg
#
# Integra com:
#   - 10-repo-metafile.sh : adm_meta_load, adm_meta_get_var, adm_repo_find_by_name, etc.
#   - 01-log-ui.sh        : adm_info, adm_warn, adm_error, adm_die
#
# Não há erros silenciosos.
# ----------------------------------------------------------------------
# Requisitos e modo seguro
# ----------------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 32-resolver-deps.sh requer bash." >&2
    exit 1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERRO: 32-resolver-deps.sh requer bash >= 4." >&2
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------
# Integração com ambiente, repo e logging
# ----------------------------------------------------------------------

ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"
ADM_REPO="${ADM_REPO:-$ADM_ROOT/repo}"

# Logging: usa 01-log-ui.sh se disponível; senão, fallback simples.
if ! declare -F adm_info >/dev/null 2>&1; then
    adm_log_ts() { date +"%Y-%m-%d %H:%M:%S"; }
    adm_info()   { printf '[%s] [INFO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_warn()   { printf '[%s] [WARN] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_error()  { printf '[%s] [ERRO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_die()    { adm_error "$*"; exit 1; }
fi

if ! declare -F adm_stage >/dev/null 2>&1; then
    adm_stage() { adm_info "===== STAGE: $* ====="; }
fi

if ! declare -F adm_ensure_dir >/dev/null 2>&1; then
    adm_ensure_dir() {
        local d="${1:-}"
        if [ -z "$d" ]; then
            adm_die "adm_ensure_dir chamado com caminho vazio"
        fi
        if [ -d "$d" ]; then
            return 0
        fi
        if ! mkdir -p "$d"; then
            adm_die "Falha ao criar diretório: $d"
        fi
    }
fi

# Sanitizadores básicos (caso 10-repo-metafile ainda não esteja carregado)
if ! declare -F adm_repo_sanitize_name >/dev/null 2>&1; then
    adm_repo_sanitize_name() {
        local n="${1:-}"
        if [ -z "$n" ]; then
            adm_die "Nome vazio não é permitido"
        fi
        if [[ ! "$n" =~ ^[A-Za-z0-9._+-]+$ ]]; then
            adm_die "Nome inválido '$n'. Use apenas [A-Za-z0-9._+-]."
        fi
        printf '%s' "$n"
    }
fi

if ! declare -F adm_repo_sanitize_category >/dev/null 2>&1; then
    adm_repo_sanitize_category() {
        local c="${1:-}"
        if [ -z "$c" ]; then
            adm_die "Categoria vazia não é permitida"
        fi
        if [[ ! "$c" =~ ^[A-Za-z0-9._+-]+$ ]]; then
            adm_die "Categoria inválida '$c'. Use apenas [A-Za-z0-9._+-]."
        fi
        printf '%s' "$c"
    }
fi

# ----------------------------------------------------------------------
# Funções de apoio para repo / metafiles
# ----------------------------------------------------------------------

# Se adm_repo_find_by_name não existir, implementamos fallback
adm_deps_find_by_name_fallback() {
    # Procura um pacote pelo nome em todas as categorias, usando ADM_REPO.
    # Retorna:
    #   - se 1 match: "categoria nome"
    #   - se 0 matches: erro
    #   - se >1: erro (ambiguidade)
    local name_raw="${1:-}"
    [ -z "$name_raw" ] && adm_die "adm_deps_find_by_name_fallback requer nome"
    local name
    name="$(adm_repo_sanitize_name "$name_raw")"

    local matches=()
    local cat_dir pkg_dir cat pkg

    if [ ! -d "$ADM_REPO" ]; then
        adm_die "ADM_REPO não existe: $ADM_REPO (não é possível procurar pacotes)"
    fi

    for cat_dir in "$ADM_REPO"/*; do
        [ -d "$cat_dir" ] || continue
        cat="$(basename "$cat_dir")"
        for pkg_dir in "$cat_dir"/*; do
            [ -d "$pkg_dir" ] || continue
            pkg="$(basename "$pkg_dir")"
            if [ "$pkg" = "$name" ]; then
                # Confirma que existe metafile
                if [ -f "$pkg_dir/metafile" ]; then
                    matches+=("$cat $pkg")
                fi
            fi
        done
    done

    local count="${#matches[@]}"
    if [ "$count" -eq 0 ]; then
        adm_die "Dependência '$name' não encontrada em nenhuma categoria do repo ($ADM_REPO)."
    elif [ "$count" -gt 1 ]; then
        adm_error "Dependência '$name' é ambígua; encontrada em múltiplas categorias:"
        local m
        for m in "${matches[@]}"; do
            adm_error "  - $m"
        done
        adm_die "Dependência ambígua '$name'; use 'categoria/nome' no metafile."
    fi

    printf '%s\n' "${matches[0]}"
}

adm_deps_find_by_name() {
    # Wrapper: usa adm_repo_find_by_name, se disponível. Senão, fallback.
    local name="${1:-}"
    [ -z "$name" ] && adm_die "adm_deps_find_by_name requer nome"

    if declare -F adm_repo_find_by_name >/dev/null 2>&1; then
        local out
        if ! out="$(adm_repo_find_by_name "$name")"; then
            adm_die "Dependência '$name' não encontrada em nenhuma categoria (adm_repo_find_by_name)."
        fi
        # adm_repo_find_by_name, como implementado no 10-repo-metafile, retorna "cat nome" da primeira ocorrência
        echo "$out"
    else
        adm_deps_find_by_name_fallback "$name"
    fi
}

adm_deps_metafile_exists() {
    local category_raw="${1:-}"
    local name_raw="${2:-}"

    [ -z "$category_raw" ] && adm_die "adm_deps_metafile_exists requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_deps_metafile_exists requer nome"

    local category name
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"

    local path="$ADM_REPO/$category/$name/metafile"
    [ -f "$path" ] || return 1
    return 0
}

# ----------------------------------------------------------------------
# Parsing de tokens de dependência (nome ou cat/nome)
# ----------------------------------------------------------------------

adm_deps_parse_token() {
    # Converte um token de dependência em "categoria nome".
    # Suporta:
    #   - "cat/pkg"
    #   - "pkg" (sem categoria -> procura em ADM_REPO)
    #
    # Uso:
    #   adm_deps_parse_token "gcc"
    #   adm_deps_parse_token "dev/gcc"
    #
    # Saída: "categoria nome"
    local token_raw="${1:-}"

    # Remove espaços nas pontas
    local token
    token="${token_raw#"${token_raw%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"

    if [ -z "$token" ]; then
        adm_die "adm_deps_parse_token chamado com token vazio (isso não deveria acontecer; verifique o metafile)."
    fi

    if [[ "$token" == */* ]]; then
        # Já tem categoria
        local category_part="${token%%/*}"
        local name_part="${token#*/}"

        local category name
        category="$(adm_repo_sanitize_category "$category_part")"
        name="$(adm_repo_sanitize_name "$name_part")"

        if ! adm_deps_metafile_exists "$category" "$name"; then
            adm_die "Dependência '$token' referenciada no metafile não existe no repo ($ADM_REPO)."
        fi

        printf '%s %s\n' "$category" "$name"
    else
        # Apenas nome -> descobrir categoria
        local res
        res="$(adm_deps_find_by_name "$token")"
        printf '%s\n' "$res"
    fi
}

adm_deps_parse_list_to_pairs() {
    # Converte uma string de deps (ex: "dep1,dep2, cat/pkg") em pares "cat nome".
    #
    # Uso:
    #   adm_deps_parse_list_to_pairs "dep1,dep2"
    # Saída:
    #   categoria1 nome1
    #   categoria2 nome2
    #
    local list="${1:-}"

    # Se vazio/nulo, nada
    if [ -z "$list" ]; then
        return 0
    fi

    local IFS=','
    local token
    for token in $list; do
        # Remover espaços
        token="${token#"${token%%[![:space:]]*}"}"
        token="${token%"${token##*[![:space:]]}"}"
        [ -z "$token" ] && continue
        adm_deps_parse_token "$token"
    done
}

# ----------------------------------------------------------------------
# Cache de metadados (para não reler metafile toda hora)
# ----------------------------------------------------------------------

# Necessita 10-repo-metafile.sh (adm_meta_load, adm_meta_get_var)
declare -Ag ADM_DEPS_META_LOADED
declare -Ag ADM_DEPS_META_RUN
declare -Ag ADM_DEPS_META_BUILD
declare -Ag ADM_DEPS_META_OPT
declare -Ag ADM_DEPS_META_VERSION

adm_deps_require_meta_api() {
    if ! declare -F adm_meta_load >/dev/null 2>&1 || \
       ! declare -F adm_meta_get_var >/dev/null 2>&1; then
        adm_die "Funções de metafile (adm_meta_load/adm_meta_get_var) não disponíveis. Carregue 10-repo-metafile.sh antes."
    fi
}

adm_deps_key() {
    local c="${1:-}"
    local n="${2:-}"
    printf '%s/%s' "$c" "$n"
}

adm_deps_load_meta_if_needed() {
    local category="${1:-}"
    local name="${2:-}"

    [ -z "$category" ] && adm_die "adm_deps_load_meta_if_needed requer categoria"
    [ -z "$name" ]     && adm_die "adm_deps_load_meta_if_needed requer nome"

    adm_deps_require_meta_api

    local key
    key="$(adm_deps_key "$category" "$name")"

    if [ "${ADM_DEPS_META_LOADED[$key]+x}" = "x" ]; then
        return 0
    fi

    adm_info "Carregando metadados para $category/$name"
    adm_meta_load "$category" "$name"

    local run build opt ver
    run="$(adm_meta_get_var "run_deps")"
    build="$(adm_meta_get_var "build_deps")"
    opt="$(adm_meta_get_var "opt_deps")"
    ver="$(adm_meta_get_var "version")"

    ADM_DEPS_META_RUN["$key"]="$run"
    ADM_DEPS_META_BUILD["$key"]="$build"
    ADM_DEPS_META_OPT["$key"]="$opt"
    ADM_DEPS_META_VERSION["$key"]="$ver"
    ADM_DEPS_META_LOADED["$key"]=1
}

adm_deps_get_deps_for_mode() {
    # Retorna string com deps (run/build/opt/all) para um pacote.
    #
    # Uso:
    #   adm_deps_get_deps_for_mode cat name mode
    #
    local category="${1:-}"
    local name="${2:-}"
    local mode="${3:-build}"

    adm_deps_load_meta_if_needed "$category" "$name"

    local key
    key="$(adm_deps_key "$category" "$name")"

    local run build opt
    run="${ADM_DEPS_META_RUN[$key]:-}"
    build="${ADM_DEPS_META_BUILD[$key]:-}"
    opt="${ADM_DEPS_META_OPT[$key]:-}"

    local res=""

    case "$mode" in
        build)
            res="$build"
            ;;
        run)
            res="$run"
            ;;
        all)
            # mista; evita duplicar nomes
            res="$run,$build,$opt"
            ;;
        *)
            adm_die "Modo de dependência desconhecido: $mode (use build|run|all)."
            ;;
    esac

    # Normaliza vírgulas múltiplas; não tem problema deixar "," extras, o parser ignora tokens vazios.
    printf '%s\n' "$res"
}

# ----------------------------------------------------------------------
# Resolução topológica (DFS com detecção de ciclos)
# ----------------------------------------------------------------------

# Estados: 0=ausente, 1=visiting, 2=done
declare -Ag ADM_DEPS_STATE
declare -a ADM_DEPS_ORDER

_adm_deps_resolve_node() {
    local category="${1:-}"
    local name="${2:-}"
    local mode="${3:-build}"

    [ -z "$category" ] && adm_die "_adm_deps_resolve_node requer categoria"
    [ -z "$name" ]     && adm_die "_adm_deps_resolve_node requer nome"

    local key
    key="$(adm_deps_key "$category" "$name")"

    local state="${ADM_DEPS_STATE[$key]:-0}"

    if [ "$state" -eq 1 ]; then
        adm_die "Detectado ciclo de dependências envolvendo $category/$name."
    elif [ "$state" -eq 2 ]; then
        return 0
    fi

    ADM_DEPS_STATE["$key"]=1

    # Expande dependências deste nó conforme modo
    local deps_str
    deps_str="$(adm_deps_get_deps_for_mode "$category" "$name" "$mode")"

    local line dep_cat dep_name
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        dep_cat="${line%% *}"
        dep_name="${line#* }"
        _adm_deps_resolve_node "$dep_cat" "$dep_name" "$mode"
    done < <(adm_deps_parse_list_to_pairs "$deps_str")

    ADM_DEPS_STATE["$key"]=2
    ADM_DEPS_ORDER+=("$category $name")
}

adm_deps_resolve_for_pkg() {
    # Função pública: resolve deps para um pacote "categoria nome".
    #
    # Uso:
    #   adm_deps_resolve_for_pkg categoria nome modo
    #
    local category_raw="${1:-}"
    local name_raw="${2:-}"
    local mode="${3:-build}"

    [ -z "$category_raw" ] && adm_die "adm_deps_resolve_for_pkg requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_deps_resolve_for_pkg requer nome"

    local category name
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"

    if ! adm_deps_metafile_exists "$category" "$name"; then
        adm_die "Metafile de $category/$name não encontrado em $ADM_REPO."
    fi

    ADM_DEPS_STATE=()
    ADM_DEPS_ORDER=()

    adm_info "Resolvendo dependências ($mode) para $category/$name..."

    _adm_deps_resolve_node "$category" "$name" "$mode"

    # ADM_DEPS_ORDER contém deps + o próprio pacote, em ordem topológica.
    # Podemos imprimir tudo ou somente os deps (sem o último), dependendo do uso.
    # Aqui imprimimos tudo, pois o build-engine geralmente quer essa ordem.
    local item
    for item in "${ADM_DEPS_ORDER[@]}"; do
        printf '%s\n' "$item"
    done
}

adm_deps_resolve_from_token() {
    # Função pública: resolve deps partindo de um token (cat/pkg ou apenas nome).
    #
    # Uso:
    #   adm_deps_resolve_from_token "gcc" build
    #   adm_deps_resolve_from_token "dev/gcc" all
    #
    local token="${1:-}"
    local mode="${2:-build}"

    [ -z "$token" ] && adm_die "adm_deps_resolve_from_token requer token"

    local pair category name
    pair="$(adm_deps_parse_token "$token")"
    category="${pair%% *}"
    name="${pair#* }"

    adm_deps_resolve_for_pkg "$category" "$name" "$mode"
}

# ----------------------------------------------------------------------
# CLI de demonstração
# ----------------------------------------------------------------------

adm_deps_usage() {
    cat <<EOF
Uso: $(basename "$0") <comando> [args...]

Comandos:
  resolve <categoria> <nome> [modo]
      - Resolve dependências para o pacote categoria/nome.
      - modo: build (padrão), run, all
      - Saída: lista em ordem topológica, um "categoria nome" por linha.

  resolve-token <token> [modo]
      - token pode ser "cat/pkg" ou apenas "pkg".
      - modo: build (padrão), run, all

  help
      - Mostra esta ajuda.

Exemplos:
  $(basename "$0") resolve dev gcc build
  $(basename "$0") resolve sys bash all
  $(basename "$0") resolve-token gcc build
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-help}"
    case "$cmd" in
        resolve)
            if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
                adm_error "Uso: $0 resolve <categoria> <nome> [modo]"
                exit 1
            fi
            catg="$2"
            pkg="$3"
            mode="${4:-build}"
            adm_deps_resolve_for_pkg "$catg" "$pkg" "$mode"
            ;;
        resolve-token)
            if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
                adm_error "Uso: $0 resolve-token <token> [modo]"
                exit 1
            fi
            token="$2"
            mode="${3:-build}"
            adm_deps_resolve_from_token "$token" "$mode"
            ;;
        help|-h|--help)
            adm_deps_usage
            ;;
        *)
            adm_error "Comando desconhecido: $cmd"
            adm_deps_usage
            exit 1
            ;;
    esac
fi
