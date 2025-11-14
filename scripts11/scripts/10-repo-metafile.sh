#!/usr/bin/env bash
# 10-repo-metafile.sh
# Gerenciamento de repositório e metafile do ADM.
#
# Layout esperado:
#   /usr/src/adm/repo/<categoria>/<programa>/
#       metafile
#       hook
#       patch/
#
# Formato do metafile (somente estas linhas, sem lixo):
#   name=programa
#   version=1.2.3
#   category=apps|libs|sys|dev|...
#   run_deps=dep1,dep2
#   build_deps=depA,depB
#   opt_deps=depX,depY
#   num_builds=0
#   description=Descrição curta
#   homepage=https://...
#   maintainer=Nome <email>
#   sha256sums=sum1,sum2
#   sources=url1,url2
#
# Todas as funções abaixo tratam erros com mensagens claras (sem erros silenciosos).
# ----------------------------------------------------------------------
# Requisitos e modo seguro
# ----------------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 10-repo-metafile.sh requer bash." >&2
    exit 1
fi
# Precisamos de bash >= 4 para algumas coisas (arrays associativos, se usarmos).
# Mesmo que hoje não exploremos muito, é bom garantir para evitar pegadinhas.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERRO: 10-repo-metafile.sh requer bash >= 4." >&2
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'
# ----------------------------------------------------------------------
# Integração com ambiente e logging
# ----------------------------------------------------------------------
ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"
ADM_REPO="${ADM_REPO:-$ADM_ROOT/repo}"
# Se 01-log-ui.sh já foi carregado, devemos ter adm_info/adm_warn/adm_error/adm_die.
# Se não, criamos fallback simples (sem cores, sem spinner).
if ! declare -F adm_info >/dev/null 2>&1; then
    adm_log_ts() { date +"%Y-%m-%d %H:%M:%S"; }
    adm_info()   { printf '[%s] [INFO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_warn()   { printf '[%s] [WARN] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_error()  { printf '[%s] [ERRO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_die()    { adm_error "$*"; exit 1; }
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
# ----------------------------------------------------------------------
# Constantes e listas de campos
# ----------------------------------------------------------------------
# Campos obrigatórios (devem existir, mesmo que vazios em alguns casos)
ADM_META_REQUIRED_KEYS=(
    name
    version
    category
    run_deps
    build_deps
    opt_deps
    num_builds
    description
    homepage
    maintainer
    sha256sums
    sources
)

# Campos que devem ser lista separada por vírgula (podem ser vazios)
ADM_META_LIST_KEYS=(
    run_deps
    build_deps
    opt_deps
    sha256sums
    sources
)

# Prefixo global das variáveis de metadados em memória
# Ex.: ADM_META_name, ADM_META_version, ADM_META_sources, etc.
ADM_META_PREFIX="ADM_META_"

# ----------------------------------------------------------------------
# Sanitização e validação de nomes
# ----------------------------------------------------------------------

adm_repo_sanitize_name() {
    # Aceita apenas [A-Za-z0-9._+-], senão erro.
    local n="${1:-}"
    if [ -z "$n" ]; then
        adm_die "Nome vazio não é permitido"
    fi
    if [[ ! "$n" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        adm_die "Nome inválido '$n'. Use apenas [A-Za-z0-9._+-]."
    fi
    printf '%s' "$n"
}

adm_repo_sanitize_category() {
    # Categoria também restrita.
    local c="${1:-}"
    if [ -z "$c" ]; then
        adm_die "Categoria vazia não é permitida"
    fi
    if [[ ! "$c" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        adm_die "Categoria inválida '$c'. Use apenas [A-Za-z0-9._+-]."
    fi
    printf '%s' "$c"
}

# ----------------------------------------------------------------------
# Funções de layout do repo
# ----------------------------------------------------------------------

adm_repo_init() {
    # Garante que o diretório do repo existe.
    adm_ensure_dir "$ADM_REPO"
}

adm_repo_pkg_base_dir() {
    # Retorna /usr/src/adm/repo/<categoria>/<nome>
    local category_raw="${1:-}"
    local name_raw="${2:-}"

    local category name
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"

    printf '%s/%s/%s' "$ADM_REPO" "$category" "$name"
}

adm_repo_pkg_metafile_path() {
    local category="${1:-}"
    local name="${2:-}"
    local base
    base="$(adm_repo_pkg_base_dir "$category" "$name")"
    printf '%s/metafile' "$base"
}

adm_repo_pkg_hook_path() {
    local category="${1:-}"
    local name="${2:-}"
    local base
    base="$(adm_repo_pkg_base_dir "$category" "$name")"
    printf '%s/hook' "$base"
}

adm_repo_pkg_patch_dir() {
    local category="${1:-}"
    local name="${2:-}"
    local base
    base="$(adm_repo_pkg_base_dir "$category" "$name")"
    printf '%s/patch' "$base"
}

adm_repo_category_list() {
    # Lista categorias disponíveis (subdirs diretos em ADM_REPO)
    adm_repo_init
    local d
    for d in "$ADM_REPO"/*; do
        [ -d "$d" ] || continue
        basename "$d"
    done | sort
}

adm_repo_pkg_list_in_category() {
    # Lista pacotes em uma categoria
    local category_raw="${1:-}"
    [ -z "$category_raw" ] && adm_die "adm_repo_pkg_list_in_category requer categoria"
    local category
    category="$(adm_repo_sanitize_category "$category_raw")"

    local dir="$ADM_REPO/$category"
    [ -d "$dir" ] || return 0

    local d
    for d in "$dir"/*; do
        [ -d "$d" ] || continue
        basename "$d"
    done | sort
}

adm_repo_pkg_exists() {
    # Retorna 0 se o pacote existe (categoria/nome com metafile)
    local category="${1:-}"
    local name="${2:-}"
    local metafile
    metafile="$(adm_repo_pkg_metafile_path "$category" "$name")"
    [ -f "$metafile" ]
}

adm_repo_find_by_name() {
    # Procura um pacote pelo nome em todas as categorias.
    # Uso: adm_repo_find_by_name "bash"
    # Saída: "categoria nome" (apenas a primeira ocorrência)
    local name_raw="${1:-}"
    [ -z "$name_raw" ] && adm_die "adm_repo_find_by_name requer o nome do programa"
    local name
    name="$(adm_repo_sanitize_name "$name_raw")"

    adm_repo_init

    local cat pkg metafile
    for cat in $(adm_repo_category_list); do
        for pkg in $(adm_repo_pkg_list_in_category "$cat"); do
            if [ "$pkg" = "$name" ]; then
                metafile="$(adm_repo_pkg_metafile_path "$cat" "$pkg")"
                if [ -f "$metafile" ]; then
                    printf '%s %s\n' "$cat" "$pkg"
                    return 0
                fi
            fi
        done
    done

    return 1
}

# ----------------------------------------------------------------------
# Gestão de ADM_META_* em memória
# ----------------------------------------------------------------------

adm_meta_clear() {
    # Remove todas as variáveis ADM_META_*
    local var
    for var in $(compgen -v "${ADM_META_PREFIX}"); do
        unset "$var" || true
    done
}

adm_meta_set_var() {
    # Define ADM_META_<key>=value
    local key="${1:-}"
    local value="${2-}"
    if [ -z "$key" ]; then
        adm_die "adm_meta_set_var chamado com key vazia"
    fi
    local var="${ADM_META_PREFIX}${key}"
    printf -v "$var" '%s' "$value"
    export "$var"
}

adm_meta_get_var() {
    # Ecoa valor de ADM_META_<key>, ou vazio se inexistente
    local key="${1:-}"
    if [ -z "$key" ]; then
        adm_die "adm_meta_get_var chamado com key vazia"
    fi
    local var="${ADM_META_PREFIX}${key}"
    printf '%s' "${!var-}"
}

adm_meta_has_key() {
    local key="${1:-}"
    if [ -z "$key" ]; then
        adm_die "adm_meta_has_key chamado com key vazia"
    fi
    local var="${ADM_META_PREFIX}${key}"
    if [ "${!var+x}" = "x" ]; then
        return 0
    fi
    return 1
}

adm_meta_debug_dump() {
    # Útil para debug
    local var
    for var in $(compgen -v "${ADM_META_PREFIX}"); do
        printf '%s=%q\n' "$var" "${!var}"
    done
}

# ----------------------------------------------------------------------
# Carregamento de metafile
# ----------------------------------------------------------------------

adm_meta_load_from_file() {
    # Carrega um metafile bruto (path), sem checar nome/categoria x repo.
    local metafile="${1:-}"
    if [ -z "$metafile" ]; then
        adm_die "adm_meta_load_from_file requer caminho do metafile"
    fi
    if [ ! -f "$metafile" ]; then
        adm_die "Metafile não encontrado: $metafile"
    fi

    adm_meta_clear

    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        # Ignora linhas em branco e comentários
        case "$line" in
            ''|'#'*) continue ;;
        esac

        # Esperamos 'chave=valor'
        if [[ "$line" != *=* ]]; then
            adm_die "Linha inválida no metafile ($metafile): '$line'"
        fi

        key="${line%%=*}"
        value="${line#*=}"

        # Remover espaços em volta da chave
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        # Não vamos cortar espaços do value; o usuário pode querer algo com espaço.
        if [ -z "$key" ]; then
            adm_die "Linha com chave vazia no metafile ($metafile): '$line'"
        fi

        adm_meta_set_var "$key" "$value"
    done <"$metafile"
}

adm_meta_load() {
    # Carrega o metafile de um pacote (categoria/nome) e valida.
    local category_raw="${1:-}"
    local name_raw="${2:-}"

    [ -z "$category_raw" ] && adm_die "adm_meta_load requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_meta_load requer nome"

    local category name metafile
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"
    metafile="$(adm_repo_pkg_metafile_path "$category" "$name")"

    adm_info "Carregando metafile: $metafile"
    adm_meta_load_from_file "$metafile"
    adm_meta_validate "$category" "$name"
}

# ----------------------------------------------------------------------
# Validação de metafile em memória
# ----------------------------------------------------------------------

adm_meta_validate() {
    # Valida todos os campos obrigatórios em ADM_META_*.
    # Se categoria/nome forem passados, confere se batem com o metafile.
    local expected_cat="${1-}"
    local expected_name="${2-}"

    local k
    for k in "${ADM_META_REQUIRED_KEYS[@]}"; do
        if ! adm_meta_has_key "$k"; then
            adm_die "Metafile inválido: campo obrigatório '$k' ausente"
        fi
    done

    local name category
    name="$(adm_meta_get_var "name")"
    category="$(adm_meta_get_var "category")"

    if [ -z "$name" ]; then
        adm_die "Metafile inválido: name vazio"
    fi
    if [ -z "$category" ]; then
        adm_die "Metafile inválido: category vazio"
    fi

    # Confere se name/category do metafile batem com o caminho, se esperado
    if [ -n "$expected_cat" ] && [ "$category" != "$expected_cat" ]; then
        adm_die "Metafile inconsistente: category='$category' mas esperado='$expected_cat'"
    fi
    if [ -n "$expected_name" ] && [ "$name" != "$expected_name" ]; then
        adm_die "Metafile inconsistente: name='$name' mas esperado='$expected_name'"
    fi

    # Garantir que listas existam (mesmo vazias)
    local key value
    for key in "${ADM_META_LIST_KEYS[@]}"; do
        value="$(adm_meta_get_var "$key")"
        if [ -z "$value" ]; then
            # Lista vazia é aceitável; grava como vazio mesmo.
            adm_meta_set_var "$key" ""
        fi
    done

    # Validar coerência sources x sha256sums
    local srcs sums n_src n_sum
    srcs="$(adm_meta_get_var "sources")"
    sums="$(adm_meta_get_var "sha256sums")"

    # Transforma em arrays pela vírgula
    IFS=',' read -r -a src_arr <<< "${srcs:-}"
    IFS=',' read -r -a sum_arr <<< "${sums:-}"

    # Contar desconsiderando strings vazias (pode haver trailing comma)
    n_src=0
    n_sum=0
    local s
    for s in "${src_arr[@]}"; do
        [ -z "$s" ] && continue
        n_src=$((n_src+1))
    done
    for s in "${sum_arr[@]}"; do
        [ -z "$s" ] && continue
        n_sum=$((n_sum+1))
    done

    if [ "$n_src" -eq 0 ]; then
        adm_die "Metafile inválido: sources vazio (é necessário pelo menos 1 source)"
    fi
    if [ "$n_sum" -ne "$n_src" ]; then
        adm_die "Metafile inválido: número de sha256sums ($n_sum) diferente de sources ($n_src)"
    fi

    # num_builds deve ser número
    local nb
    nb="$(adm_meta_get_var "num_builds")"
    if [ -z "$nb" ]; then
        nb="0"
        adm_meta_set_var "num_builds" "$nb"
    fi
    if [[ ! "$nb" =~ ^[0-9]+$ ]]; then
        adm_die "Metafile inválido: num_builds='$nb' não é inteiro"
    fi
}

# ----------------------------------------------------------------------
# Salvamento de metafile (canonicalizado)
# ----------------------------------------------------------------------

adm_meta_save_to_file() {
    # Salva ADM_META_* no arquivo indicado, sobrescrevendo.
    local metafile="${1:-}"
    if [ -z "$metafile" ]; then
        adm_die "adm_meta_save_to_file requer caminho do metafile"
    fi

    local dir
    dir="$(dirname "$metafile")"
    adm_ensure_dir "$dir"

    # Valida antes de salvar (sem categoria/nome esperados)
    adm_meta_validate

    # Para evitar corromper arquivo em caso de erro, escrevemos em temp e depois movemos.
    local tmp="${metafile}.tmp.$$"

    # Ordem fixa de campos, conforme especificação.
    local name category version run_deps build_deps opt_deps num_builds description homepage maintainer sha256sums sources

    name="$(adm_meta_get_var "name")"
    category="$(adm_meta_get_var "category")"
    version="$(adm_meta_get_var "version")"
    run_deps="$(adm_meta_get_var "run_deps")"
    build_deps="$(adm_meta_get_var "build_deps")"
    opt_deps="$(adm_meta_get_var "opt_deps")"
    num_builds="$(adm_meta_get_var "num_builds")"
    description="$(adm_meta_get_var "description")"
    homepage="$(adm_meta_get_var "homepage")"
    maintainer="$(adm_meta_get_var "maintainer")"
    sha256sums="$(adm_meta_get_var "sha256sums")"
    sources="$(adm_meta_get_var "sources")"

    {
        printf 'name=%s\n' "$name"
        printf 'version=%s\n' "$version"
        printf 'category=%s\n' "$category"
        printf 'run_deps=%s\n' "$run_deps"
        printf 'build_deps=%s\n' "$build_deps"
        printf 'opt_deps=%s\n' "$opt_deps"
        printf 'num_builds=%s\n' "$num_builds"
        printf 'description=%s\n' "$description"
        printf 'homepage=%s\n' "$homepage"
        printf 'maintainer=%s\n' "$maintainer"
        printf 'sha256sums=%s\n' "$sha256sums"
        printf 'sources=%s\n' "$sources"
    } >"$tmp"

    # Move atômico (no mesmo FS)
    if ! mv -f "$tmp" "$metafile"; then
        rm -f "$tmp" || true
        adm_die "Falha ao salvar metafile em '$metafile'"
    fi
}

adm_meta_save() {
    # Salva ADM_META_* no metafile do pacote (categoria/nome).
    local category_raw="${1:-}"
    local name_raw="${2:-}"

    [ -z "$category_raw" ] && adm_die "adm_meta_save requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_meta_save requer nome"

    local category name metafile
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"
    metafile="$(adm_repo_pkg_metafile_path "$category" "$name")"

    # Garante coerência de name/category antes de salvar
    adm_meta_set_var "category" "$category"
    adm_meta_set_var "name" "$name"

    adm_info "Salvando metafile: $metafile"
    adm_meta_save_to_file "$metafile"
}

adm_meta_increment_builds() {
    # Incrementa num_builds e salva o metafile.
    local category_raw="${1:-}"
    local name_raw="${2:-}"

    adm_meta_load "$category_raw" "$name_raw"

    local nb
    nb="$(adm_meta_get_var "num_builds")"
    if [ -z "$nb" ] || [[ ! "$nb" =~ ^[0-9]+$ ]]; then
        adm_warn "num_builds inválido ou vazio; redefinindo para 0 antes de incrementar"
        nb=0
    fi
    nb=$((nb + 1))
    adm_meta_set_var "num_builds" "$nb"

    adm_info "Incrementando num_builds para $nb (pacote ${name_raw} / ${category_raw})"
    adm_meta_save "$category_raw" "$name_raw"
}

# ----------------------------------------------------------------------
# Utilitários de alto nível
# ----------------------------------------------------------------------

adm_meta_get_field() {
    # Imprime o valor de um campo de metafile de pacote.
    # Uso: adm_meta_get_field categoria nome campo
    local category="${1:-}"
    local name="${2:-}"
    local field="${3:-}"

    [ -z "$field" ] && adm_die "adm_meta_get_field requer campo"

    adm_meta_load "$category" "$name"
    adm_meta_get_var "$field"
}

adm_meta_set_field_and_save() {
    # Seta um campo e salva o metafile.
    # Uso: adm_meta_set_field_and_save categoria nome campo valor
    local category="${1:-}"
    local name="${2:-}"
    local field="${3:-}"
    local value="${4-}"

    [ -z "$field" ] && adm_die "adm_meta_set_field_and_save requer campo"

    adm_meta_load "$category" "$name"
    adm_meta_set_var "$field" "$value"
    adm_meta_save "$category" "$name"
}

# ----------------------------------------------------------------------
# Comportamento ao ser executado diretamente (demo)
# ----------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    adm_info "10-repo-metafile.sh executado diretamente (modo demonstração)."

    adm_repo_init

    echo "Categorias disponíveis:"
    adm_repo_category_list || true
    echo

    # Se usuário passar argumentos, tentamos carregar um pacote:
    #   ./10-repo-metafile.sh categoria nome
    if [ "$#" -ge 2 ]; then
        catg="$1"
        pkg="$2"
        adm_info "Carregando metafile de '$catg/$pkg'..."
        set +e
        if adm_meta_load "$catg" "$pkg"; then
            set -e
            echo "Metadados carregados:"
            adm_meta_debug_dump
        else
            rc=$?
            set -e
            adm_error "Falha ao carregar metafile de '$catg/$pkg' (rc=$rc)"
            exit "$rc"
        fi
    else
        adm_info "Nenhum pacote especificado para demo. Use: $0 categoria nome"
    fi
fi
