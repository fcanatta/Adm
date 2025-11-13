#!/usr/bin/env bash
# lib/adm/repo.sh
#
# Camada de repositório do ADM:
#   - Organização: /repo/<categoria>/<pacote>/
#   - Metafile: repo/<categoria>/<pacote>/metafile
#   - Diretórios: patches/, hooks/
#   - Criação de novos pacotes: adm_repo_create_metafile
#   - Leitura/validação de metafile: adm_repo_load_metafile
#   - Listagem de categorias/pacotes
#
# Objetivo: zero erros silenciosos – qualquer problema relevante gera log claro.
#===============================================================================
# Proteção contra múltiplos loads
#===============================================================================
if [ -n "${ADM_REPO_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
ADM_REPO_LOADED=1
#===============================================================================
# Dependências: log + core + env_profiles
#===============================================================================
if ! command -v adm_log_info >/dev/null 2>&1; then
    # Fallback mínimo se log.sh ainda não foi carregado
    adm_log()       { printf '%s\n' "$*" >&2; }
    adm_log_info()  { adm_log "[INFO]  $*"; }
    adm_log_warn()  { adm_log "[WARN]  $*"; }
    adm_log_error() { adm_log "[ERROR] $*"; }
    adm_log_debug() { :; }
fi

if ! command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_log_error "repo.sh requer core.sh (função adm_core_init_paths não encontrada)."
else
    adm_core_init_paths
fi

# Garante defaults de paths principais
: "${ADM_REPO_DIR:=${ADM_ROOT:-/usr/src/adm}/repo}"
#===============================================================================
# Helpers internos simples
#===============================================================================
adm_repo__validate_identifier() {
    # Verifica se string é um identificador simples: letras, números, -, _ e .
    # Uso: adm_repo__validate_identifier "nome" || return 1
    if [ $# -ne 1 ]; then
        adm_log_error "adm_repo__validate_identifier requer 1 argumento."
        return 1
    fi
    local s="$1"
    if [ -z "$s" ]; then
        adm_log_error "Identificador não pode ser vazio."
        return 1
    fi
    case "$s" in
        *[!A-Za-z0-9._-]*)
            adm_log_error "Identificador inválido: '%s' (permitido: letras, números, ., -, _)" "$s"
            return 1
            ;;
    esac
    return 0
}

#===============================================================================
# Caminhos principais do repositório
#===============================================================================
# Diretório da categoria
# Uso: adm_repo_category_dir categoria
adm_repo_category_dir() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_repo_category_dir requer 1 argumento: CATEGORIA"
        return 1
    fi
    local category="$1"

    adm_repo__validate_identifier "$category" || return 1
    printf '%s/%s\n' "$ADM_REPO_DIR" "$category"
    return 0
}

# Diretório do pacote
# Uso: adm_repo_pkg_dir categoria pacote
adm_repo_pkg_dir() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_repo_pkg_dir requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local category="$1"
    local pkg="$2"

    adm_repo__validate_identifier "$category" || return 1
    adm_repo__validate_identifier "$pkg"      || return 1

    local cat_dir
    cat_dir="$(adm_repo_category_dir "$category")" || return 1
    printf '%s/%s\n' "$cat_dir" "$pkg"
    return 0
}

# Caminho do metafile de um pacote
# Uso: adm_repo_metafile_path categoria pacote
adm_repo_metafile_path() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_repo_metafile_path requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi

    local pkg_dir
    pkg_dir="$(adm_repo_pkg_dir "$1" "$2")" || return 1
    printf '%s/metafile\n' "$pkg_dir"
    return 0
}

# Diretórios hooks/ e patches/
adm_repo_hooks_dir() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_repo_hooks_dir requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local pkg_dir
    pkg_dir="$(adm_repo_pkg_dir "$1" "$2")" || return 1
    printf '%s/hooks\n' "$pkg_dir"
    return 0
}

adm_repo_patches_dir() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_repo_patches_dir requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local pkg_dir
    pkg_dir="$(adm_repo_pkg_dir "$1" "$2")" || return 1
    printf '%s/patches\n' "$pkg_dir"
    return 0
}

#===============================================================================
# Criação de diretórios e hooks default
#===============================================================================
# Cria diretórios padrão do pacote (pkg_dir, hooks/, patches/)
adm_repo_ensure_pkg_dirs() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_repo_ensure_pkg_dirs requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi

    local category="$1" pkg="$2"
    local pkg_dir hooks_dir patches_dir

    pkg_dir="$(adm_repo_pkg_dir "$category" "$pkg")" || return 1
    hooks_dir="$(adm_repo_hooks_dir "$category" "$pkg")" || return 1
    patches_dir="$(adm_repo_patches_dir "$category" "$pkg")" || return 1

    adm_mkdir_p "$pkg_dir"     || { adm_log_error "Falha ao criar diretório do pacote: %s" "$pkg_dir"; return 1; }
    adm_mkdir_p "$hooks_dir"   || { adm_log_error "Falha ao criar diretório hooks: %s" "$hooks_dir"; return 1; }
    adm_mkdir_p "$patches_dir" || { adm_log_error "Falha ao criar diretório patches: %s" "$patches_dir"; return 1; }

    return 0
}

# Hooks padrões a serem criados
adm_repo__default_hooks_list() {
    cat <<EOF
pre_fetch
post_fetch
pre_configure
post_configure
pre_build
post_build
pre_install
post_install
pre_uninstall
post_uninstall
test
EOF
}

# Cria hooks default (se não existirem)
adm_repo_ensure_default_hooks() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_repo_ensure_default_hooks requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi

    local category="$1" pkg="$2"
    local hooks_dir
    hooks_dir="$(adm_repo_hooks_dir "$category" "$pkg")" || return 1

    adm_mkdir_p "$hooks_dir" || {
        adm_log_error "Falha ao criar diretório de hooks: %s" "$hooks_dir"
        return 1
    }

    local hook
    while IFS= read -r hook || [ -n "$hook" ]; do
        [ -z "$hook" ] && continue
        local hook_path="$hooks_dir/$hook"

        if [ -e "$hook_path" ]; then
            # Não sobrescreve hooks existentes
            continue
        fi

        {
            printf '#!/usr/bin/env bash\n'
            printf '# Hook: %s\n' "$hook"
            printf '# Gerado automaticamente pelo ADM. Edite se precisar de customizações.\n'
            printf 'exit 0\n'
        } >"$hook_path" 2>/dev/null || {
            adm_log_error "Falha ao criar hook default: %s" "$hook_path"
            return 1
        }
        chmod +x "$hook_path" 2>/dev/null || {
            adm_log_warn "Não foi possível tornar executável o hook: %s" "$hook_path"
        }
    done <<EOF
$(adm_repo__default_hooks_list)
EOF

    return 0
}

#===============================================================================
# Criação de metafile (adm --create-metafile categoria pacote)
#===============================================================================

# Gera conteúdo padrão de metafile
adm_repo__write_default_metafile() {
    if [ $# -ne 3 ]; then
        adm_log_error "adm_repo__write_default_metafile requer 3 argumentos: CATEGORIA PACOTE ARQUIVO"
        return 1
    fi
    local category="$1" pkg="$2" file="$3"

    {
        printf 'name=%s\n'       "$pkg"
        printf 'version=\n'
        printf 'category=%s\n'   "$category"
        printf 'run_deps=\n'
        printf 'build_deps=\n'
        printf 'opt_deps=\n'
        printf 'num_builds=0\n'
        printf 'description=\n'
        printf 'homepage=\n'
        printf 'maintainer=\n'
        printf 'sha256sums=\n'
        printf 'sources=\n'
    } >"$file" 2>/dev/null || {
        adm_log_error "Falha ao escrever metafile padrão em: %s" "$file"
        return 1
    }

    return 0
}

# Cria pacote (metafile + diretórios + hooks)
# Uso externo (pela CLI): adm_repo_create_metafile base gcc
adm_repo_create_metafile() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_repo_create_metafile requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi

    local category="$1" pkg="$2"

    adm_repo__validate_identifier "$category" || return 1
    adm_repo__validate_identifier "$pkg"      || return 1

    local pkg_dir metafile
    pkg_dir="$(adm_repo_pkg_dir "$category" "$pkg")" || return 1
    metafile="$(adm_repo_metafile_path "$category" "$pkg")" || return 1

    # Cria diretórios e hooks
    adm_repo_ensure_pkg_dirs "$category" "$pkg" || return 1
    adm_repo_ensure_default_hooks "$category" "$pkg" || return 1

    if [ -f "$metafile" ]; then
        adm_log_warn "metafile já existe para %s/%s: %s (não será sobrescrito)" "$category" "$pkg" "$metafile"
        return 0
    fi

    adm_repo__write_default_metafile "$category" "$pkg" "$metafile" || return 1

    adm_log_info "metafile criado: %s (categoria=%s, pacote=%s)" "$metafile" "$category" "$pkg"
    return 0
}

#===============================================================================
# Leitura e validação de metafile
#===============================================================================

# Campos esperados no metafile
adm_repo__metafile_required_keys() {
    cat <<EOF
name
version
category
num_builds
sources
sha256sums
EOF
}

adm_repo__metafile_optional_keys() {
    cat <<EOF
run_deps
build_deps
opt_deps
description
homepage
maintainer
EOF
}

# Lê metafile para um pacote e exporta variáveis com prefixo
# Uso: adm_repo_load_metafile categoria pacote PREFIX_
#
# Exemplo:
#   adm_repo_load_metafile base gcc ADM_META_
#   → ADM_META_name, ADM_META_version, etc.
adm_repo_load_metafile() {
    if [ $# -ne 3 ]; then
        adm_log_error "adm_repo_load_metafile requer 3 argumentos: CATEGORIA PACOTE PREFIXO"
        return 1
    fi

    local category="$1" pkg="$2" prefix="$3"
    local metafile pkg_dir

    if [ -z "$prefix" ]; then
        adm_log_error "adm_repo_load_metafile: PREFIXO não pode ser vazio."
        return 1
    fi

    adm_repo__validate_identifier "$category" || return 1
    adm_repo__validate_identifier "$pkg"      || return 1

    pkg_dir="$(adm_repo_pkg_dir "$category" "$pkg")" || return 1
    metafile="$(adm_repo_metafile_path "$category" "$pkg")" || return 1

    if [ ! -f "$metafile" ]; then
        adm_log_error "metafile não encontrado para %s/%s: %s" "$category" "$pkg" "$metafile"
        return 1
    fi

    if ! command -v adm_read_kv_file >/dev/null 2>&1; then
        adm_log_error "adm_read_kv_file não disponível; não foi possível ler metafile: %s" "$metafile"
        return 1
    fi

    adm_read_kv_file "$metafile" "$prefix" || {
        adm_log_error "Falha ao ler metafile: %s" "$metafile"
        return 1
    }

    # Garante que todas as chaves existam como variáveis (nem que sejam vazias)
    local key varname
    while IFS= read -r key || [ -n "$key" ]; do
        [ -z "$key" ] && continue
        varname="${prefix}${key}"
        # shellcheck disable=SC2163
        eval ": \"\${$varname:=}\""
    done <<EOF
$(adm_repo__metafile_required_keys)
$(adm_repo__metafile_optional_keys)
EOF

    # Valida chaves obrigatórias
    local missing=0
    while IFS= read -r key || [ -n "$key" ]; do
        [ -z "$key" ] && continue
        varname="${prefix}${key}"
        # shellcheck disable=SC2016
        eval 'val="$'"$varname"'"'
        if [ -z "$val" ]; then
            adm_log_error "metafile %s: campo obrigatório '%s' está vazio." "$metafile" "$key"
            missing=1
        fi
    done <<EOF
$(adm_repo__metafile_required_keys)
EOF

    if [ "$missing" -ne 0 ]; then
        adm_log_error "metafile inválido (campos obrigatórios vazios): %s" "$metafile"
        return 1
    fi

    # Consistência: name/category vs diretório
    local meta_name meta_cat
    # shellcheck disable=SC2016
    eval 'meta_name="$'"${prefix}name"'"'
    eval 'meta_cat="$'"${prefix}category"'"'

    if [ "$meta_name" != "$pkg" ]; then
        adm_log_warn "metafile %s: name='%s' não confere com pacote '%s'." "$metafile" "$meta_name" "$pkg"
    fi
    if [ "$meta_cat" != "$category" ]; then
        adm_log_warn "metafile %s: category='%s' não confere com diretório '%s'." "$metafile" "$meta_cat" "$category"
    fi

    adm_log_debug "metafile carregado (%s/%s): version=%s" "$category" "$pkg" "$(eval 'printf "%s" "$'"${prefix}version"'"')"
    return 0
}

#===============================================================================
# Utilidades de deps (parse de listas simples)
#===============================================================================

# Converte string "dep1,dep2, dep3" em lista de linhas:
# Uso: adm_repo_parse_deps "dep1,dep2" → imprime "dep1\ndep2\n"
adm_repo_parse_deps() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_repo_parse_deps requer 1 argumento: STRING_DE_DEPS"
        return 1
    fi

    local s="$1"
    local item

    # troca vírgulas por quebras de linha
    printf '%s\n' "$s" | tr ',' '\n' | while IFS= read -r item || [ -n "$item" ]; do
        # remove espaços nas pontas
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [ -z "$item" ] && continue
        printf '%s\n' "$item"
    done

    return 0
}

#===============================================================================
# Listagem de categorias e pacotes
#===============================================================================

# Lista categorias (nomes de subdirs em ADM_REPO_DIR)
adm_repo_list_categories() {
    local d found=0

    if [ ! -d "$ADM_REPO_DIR" ]; then
        adm_log_warn "ADM_REPO_DIR não existe: %s" "$ADM_REPO_DIR"
        return 0
    fi

    for d in "$ADM_REPO_DIR"/*; do
        [ -d "$d" ] || continue
        printf '%s\n' "${d##*/}"
        found=1
    done

    if [ $found -eq 0 ]; then
        adm_log_warn "Nenhuma categoria encontrada em: %s" "$ADM_REPO_DIR"
    fi
}

# Lista pacotes de uma categoria
# Uso: adm_repo_list_packages categoria
adm_repo_list_packages() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_repo_list_packages requer 1 argumento: CATEGORIA"
        return 1
    fi

    local category="$1" cat_dir p found=0

    cat_dir="$(adm_repo_category_dir "$category")" || return 1

    if [ ! -d "$cat_dir" ]; then
        adm_log_warn "Categoria inexiste ou vazia: %s" "$cat_dir"
        return 0
    fi

    for p in "$cat_dir"/*; do
        [ -d "$p" ] || continue
        printf '%s\n' "${p##*/}"
        found=1
    done

    if [ $found -eq 0 ]; then
        adm_log_warn "Nenhum pacote encontrado na categoria: %s" "$category"
    fi
}

#===============================================================================
# Inicialização
#===============================================================================

adm_repo_init() {
    # Garante que ADM_REPO_DIR exista
    if ! adm_mkdir_p "$ADM_REPO_DIR"; then
        adm_log_error "Falha ao criar ADM_REPO_DIR: %s" "$ADM_REPO_DIR"
        return 1
    fi
    adm_log_debug "Repositório inicializado em: %s" "$ADM_REPO_DIR"
    return 0
}

adm_repo_init
