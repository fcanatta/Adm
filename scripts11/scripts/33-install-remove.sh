#!/usr/bin/env bash
# 33-install-remove.sh
# Instalação e remoção de pacotes do ADM.
#
# Integra com:
#   - 10-repo-metafile.sh  (adm_meta_load, adm_meta_get_var)
#   - 31-build-engine.sh   (adm_build_pkg, adm_build_pkg_from_token, adm_build_get_version)
#   - 32-resolver-deps.sh  (adm_deps_resolve_for_pkg / adm_deps_resolve_from_token / adm_deps_parse_token)
#   - 01-log-ui.sh         (adm_info, adm_warn, adm_error, adm_die, adm_run_with_spinner)
#
# Conceitos:
#   - Sempre instala via DESTDIR de staging:
#       ADM_STAGING_ROOT/<categoria>/<nome>/<versao>/XXXX/
#     Depois copia para o ROOT final (por default "/").
#
#   - DB de pacotes instalados:
#       ADM_DB_ROOT (base, default: /usr/src/adm/db)
#       ADM_DB_ROOT/installs/<root_id>/packages/<categoria>/<nome>/<versao>/
#           manifest
#           files.list
#
#   - root_id é derivado do destroot ("/" => "host", outros: string sanitizada do caminho).
#
# Funções principais (API):
#   adm_pkg_install <categoria> <nome> <modo> <root>
#   adm_pkg_install_from_token <token> <modo> <root>
#   adm_pkg_remove <categoria> <nome> <root>
#   adm_pkg_remove_from_token <token> <root>
#   adm_pkg_list_installed [root]
#   adm_pkg_query <categoria> <nome> [root]
#
# CLI (quando executado diretamente):
#   33-install-remove.sh install        <categoria> <nome> [modo] [root]
#   33-install-remove.sh install-token  <token>     [modo] [root]
#   33-install-remove.sh remove         <categoria> <nome> [root]
#   33-install-remove.sh remove-token   <token>     [root]
#   33-install-remove.sh list           [root]
#   33-install-remove.sh query          <categoria> <nome> [root]
#   33-install-remove.sh help

# ----------------------------------------------------------------------
# Requisitos e modo seguro
# ----------------------------------------------------------------------

if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 33-install-remove.sh requer bash." >&2
    exit 1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERRO: 33-install-remove.sh requer bash >= 4." >&2
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------
# Ambiente e logging
# ----------------------------------------------------------------------

ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"
ADM_SCRIPTS="${ADM_SCRIPTS:-$ADM_ROOT/scripts}"
ADM_REPO="${ADM_REPO:-$ADM_ROOT/repo}"
ADM_WORK="${ADM_WORK:-$ADM_ROOT/work}"

ADM_STAGING_ROOT="${ADM_STAGING_ROOT:-$ADM_ROOT/staging}"
ADM_DB_ROOT="${ADM_DB_ROOT:-$ADM_ROOT/db}"

# Logging: se 01-log-ui.sh já foi carregado, usamos; senão, fallback simples.
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

if ! declare -F adm_run_with_spinner >/dev/null 2>&1; then
    adm_run_with_spinner() {
        local msg="$1"; shift
        adm_info "$msg"
        "$@"
    }
fi

# Sanitizadores (caso 10-repo-metafile ainda não esteja carregado)
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
# Dependências obrigatórias (build engine + metafile)
# ----------------------------------------------------------------------

if ! declare -F adm_build_pkg >/dev/null 2>&1; then
    adm_die "adm_build_pkg não disponível. Carregue 31-build-engine.sh antes de usar 33-install-remove.sh."
fi

if ! declare -F adm_build_get_version >/dev/null 2>&1; then
    adm_die "adm_build_get_version não disponível. Carregue 31-build-engine.sh (ou equivalente) antes."
fi

if ! declare -F adm_meta_load >/dev/null 2>&1 || \
   ! declare -F adm_meta_get_var >/dev/null 2>&1; then
    adm_die "Funções de metafile (adm_meta_load/adm_meta_get_var) não disponíveis. Carregue 10-repo-metafile.sh."
fi

# Para tokens "pkg" sem categoria, usamos parse do resolver se existir
ADM_HAS_DEPS_TOKEN_PARSE=0
if declare -F adm_deps_parse_token >/dev/null 2>&1; then
    ADM_HAS_DEPS_TOKEN_PARSE=1
fi

# ----------------------------------------------------------------------
# Helpers de root / DB / staging
# ----------------------------------------------------------------------

adm_install_root_normalize() {
    local root="${1:-/}"
    [ -z "$root" ] && root="/"
    # Normalizar // -> /
    root="$(printf '%s' "$root" | sed 's://*:/:g')"
    printf '%s\n' "$root"
}

adm_install_root_id() {
    # root "/" => "host"
    # outros => string sanitizada (/usr/src/adm/rootfs-stage1 -> usr_src_adm_rootfs-stage1)
    local root
    root="$(adm_install_root_normalize "${1:-/}")"

    if [ "$root" = "/" ]; then
        printf '%s\n' "host"
        return 0
    fi

    local id
    id="$(printf '%s' "$root" | sed 's:[^A-Za-z0-9._-]:_:g')"
    [ -z "$id" ] && id="root"
    printf '%s\n' "$id"
}

adm_install_require_root_if_needed() {
    local root
    root="$(adm_install_root_normalize "${1:-/}")"
    if [ "$root" = "/" ]; then
        if [ "$(id -u)" -ne 0 ]; then
            adm_die "Instalação no root '/' requer privilégios de root."
        fi
    fi
}

adm_install_db_root_for() {
    local root="${1:-/}"
    local root_id
    root_id="$(adm_install_root_id "$root")"
    printf '%s/installs/%s' "$ADM_DB_ROOT" "$root_id"
}

adm_install_pkg_db_dir() {
    local category="${1:-}" name="${2:-}" version="${3:-}" root="${4:-/}"

    [ -z "$category" ] && adm_die "adm_install_pkg_db_dir requer categoria"
    [ -z "$name" ]     && adm_die "adm_install_pkg_db_dir requer nome"
    [ -z "$version" ]  && adm_die "adm_install_pkg_db_dir requer versao"

    local c n
    c="$(adm_repo_sanitize_category "$category")"
    n="$(adm_repo_sanitize_name "$name")"

    local dbroot
    dbroot="$(adm_install_db_root_for "$root")"

    printf '%s/packages/%s/%s/%s' "$dbroot" "$c" "$n" "$version"
}

adm_install_staging_dir_for() {
    local category="${1:-}" name="${2:-}" version="${3:-}"

    [ -z "$category" ] && adm_die "adm_install_staging_dir_for requer categoria"
    [ -z "$name" ]     && adm_die "adm_install_staging_dir_for requer nome"
    [ -z "$version" ]  && adm_die "adm_install_staging_dir_for requer versao"

    local c n
    c="$(adm_repo_sanitize_category "$category")"
    n="$(adm_repo_sanitize_name "$name")"

    printf '%s/%s/%s/%s' "$ADM_STAGING_ROOT" "$c" "$n" "$version"
}

# ----------------------------------------------------------------------
# Helpers de parse de token (cat/pkg ou pkg)
# ----------------------------------------------------------------------

adm_install_parse_token() {
    local token_raw="${1:-}"
    local token
    token="${token_raw#"${token_raw%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"

    if [ -z "$token" ]; then
        adm_die "adm_install_parse_token chamado com token vazio."
    fi

    if [[ "$token" == */* ]]; then
        local category_part="${token%%/*}"
        local name_part="${token#*/}"
        local c n
        c="$(adm_repo_sanitize_category "$category_part")"
        n="$(adm_repo_sanitize_name "$name_part")"
        printf '%s %s\n' "$c" "$n"
    else
        if [ "$ADM_HAS_DEPS_TOKEN_PARSE" -eq 1 ]; then
            adm_deps_parse_token "$token"
        else
            # fallback: busca no ADM_REPO
            local name
            name="$(adm_repo_sanitize_name "$token")"
            local matches=() cat_dir pkg_dir cat pkg

            if [ ! -d "$ADM_REPO" ]; then
                adm_die "ADM_REPO não existe: $ADM_REPO (não é possível resolver '$token')."
            fi

            for cat_dir in "$ADM_REPO"/*; do
                [ -d "$cat_dir" ] || continue
                cat="$(basename "$cat_dir")"
                for pkg_dir in "$cat_dir"/*; do
                    [ -d "$pkg_dir" ] || continue
                    pkg="$(basename "$pkg_dir")"
                    if [ "$pkg" = "$name" ] && [ -f "$pkg_dir/metafile" ]; then
                        matches+=("$cat $pkg")
                    fi
                done
            done

            local count="${#matches[@]}"
            if [ "$count" -eq 0 ]; then
                adm_die "Pacote '$name' não encontrado em nenhuma categoria do repo."
            elif [ "$count" -gt 1 ]; then
                adm_error "Pacote '$name' é ambíguo; múltiplas categorias:"
                local m
                for m in "${matches[@]}"; do
                    adm_error "  - $m"
                done
                adm_die "Use 'categoria/nome' para esse pacote."
            fi
            printf '%s\n' "${matches[0]}"
        fi
    fi
}

# ----------------------------------------------------------------------
# DB de instalação: helpers
# ----------------------------------------------------------------------

adm_install_pkg_manifest_path() {
    local category="${1:-}" name="${2:-}" version="${3:-}" root="${4:-/}"
    local dbdir
    dbdir="$(adm_install_pkg_db_dir "$category" "$name" "$version" "$root")"
    printf '%s/manifest' "$dbdir"
}

adm_install_pkg_files_list_path() {
    local category="${1:-}" name="${2:-}" version="${3:-}" root="${4:-/}"
    local dbdir
    dbdir="$(adm_install_pkg_db_dir "$category" "$name" "$version" "$root")"
    printf '%s/files.list' "$dbdir"
}

adm_install_pkg_is_installed() {
    local category="${1:-}" name="${2:-}" version="${3:-}" root="${4:-/}"
    local dbdir
    dbdir="$(adm_install_pkg_db_dir "$category" "$name" "$version" "$root")"
    [ -d "$dbdir" ]
}

adm_install_list_versions_for_pkg() {
    local category="${1:-}" name="${2:-}" root="${3:-/}"

    [ -z "$category" ] && adm_die "adm_install_list_versions_for_pkg requer categoria"
    [ -z "$name" ]     && adm_die "adm_install_list_versions_for_pkg requer nome"

    local c n dbroot pkgdir
    c="$(adm_repo_sanitize_category "$category")"
    n="$(adm_repo_sanitize_name "$name")"
    dbroot="$(adm_install_db_root_for "$root")"
    pkgdir="$dbroot/packages/$c/$n"

    [ -d "$pkgdir" ] || return 0

    local d
    for d in "$pkgdir"/*; do
        [ -d "$d" ] || continue
        basename "$d"
    done | sort
}

adm_install_list_pkgs_for_root() {
    local root="${1:-/}"
    local dbroot
    dbroot="$(adm_install_db_root_for "$root")"

    [ -d "$dbroot/packages" ] || return 0

    local cat_dir pkg_dir ver_dir cat pkg ver
    for cat_dir in "$dbroot/packages"/*; do
        [ -d "$cat_dir" ] || continue
        cat="$(basename "$cat_dir")"
        for pkg_dir in "$cat_dir"/*; do
            [ -d "$pkg_dir" ] || continue
            pkg="$(basename "$pkg_dir")"
            for ver_dir in "$pkg_dir"/*; do
                [ -d "$ver_dir" ] || continue
                ver="$(basename "$ver_dir")"
                printf '%s %s %s\n' "$cat" "$pkg" "$ver"
            done
        done
    done | sort
}

# ----------------------------------------------------------------------
# Staging: construir pacote em DESTDIR temporário
# ----------------------------------------------------------------------

adm_install_build_to_staging() {
    local category="${1:-}" name="${2:-}" mode="${3:-build}"

    local version
    version="$(adm_build_get_version "$category" "$name")"

    local base staging
    base="$(adm_install_staging_dir_for "$category" "$name" "$version")"
    # staging único por execução
    staging="$base/adm-$$-$RANDOM"

    # Garantir staging limpo
    if [ -d "$staging" ]; then
        adm_warn "Staging dir já existe (estranho): $staging; removendo."
        rm -rf --one-file-system "$staging" || adm_die "Falha ao limpar $staging"
    fi
    adm_ensure_dir "$staging"

    adm_stage "BUILD-STAGING $category/$name-$version (mode=$mode, destdir=$staging)"

    adm_run_with_spinner "Construindo $category/$name em staging" \
        adm_build_pkg "$category" "$name" "$mode" "$staging"

    # Verifica se staging não está vazio
    if ! find "$staging" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        adm_die "Staging '$staging' está vazio após build de $category/$name-$version."
    fi

    printf '%s\n' "$staging"
}

# ----------------------------------------------------------------------
# Instalação: copiar staging -> root, com checagem de conflitos
# ----------------------------------------------------------------------

adm_install_copy_staging_to_root() {
    local staging="${1:-}" root="${2:-/}"

    [ -z "$staging" ] && adm_die "adm_install_copy_staging_to_root requer staging"
    [ -d "$staging" ] || adm_die "Staging não existe: $staging"

    root="$(adm_install_root_normalize "$root")"
    adm_install_require_root_if_needed "$root"

    adm_stage "COPY-STAGING -> ROOT (staging=$staging, root=$root)"

    # Percorrer staging de forma ordenada
    # Captura caminhos com prefixo ./ e ordena por profundidade (cria dirs antes)
    local list
    list="$(cd "$staging" && find . -mindepth 1 -print | sort)"

    local entry rel target path_type
    while IFS= read -r entry || [ -n "$entry" ]; do
        [ -z "$entry" ] && continue
        rel="${entry#./}"
        [ -z "$rel" ] && continue
        target="$root/$rel"

        path_type=""
        if [ -L "$staging/$rel" ]; then
            path_type="symlink"
        elif [ -d "$staging/$rel" ]; then
            path_type="dir"
        elif [ -f "$staging/$rel" ]; then
            path_type="file"
        else
            adm_warn "Entrada desconhecida em staging (ignorando): $staging/$rel"
            continue
        fi

        case "$path_type" in
            dir)
                if [ -d "$target" ]; then
                    # ok
                    :
                elif [ -e "$target" ]; then
                    adm_die "Conflito: $target já existe e não é diretório."
                else
                    adm_info "Criando diretório: $target"
                    if ! mkdir -p "$target"; then
                        adm_die "Falha ao criar diretório $target"
                    fi
                fi
                ;;
            symlink)
                # Se já existe algo em target, checar
                if [ -L "$target" ] || [ -f "$target" ] || [ -d "$target" ]; then
                    # Verificar se é o mesmo link
                    local src_link new_link
                    new_link="$(readlink "$staging/$rel")"
                    if [ -L "$target" ]; then
                        src_link="$(readlink "$target")"
                        if [ "$src_link" = "$new_link" ]; then
                            adm_info "Link simbólico já existente e idêntico: $target"
                            continue
                        fi
                    fi
                    adm_die "Conflito: $target já existe (não é link idêntico)."
                fi
                adm_info "Criando link: $target -> $(readlink "$staging/$rel")"
                if ! ln -s "$(readlink "$staging/$rel")" "$target"; then
                    adm_die "Falha ao criar link simbólico $target"
                fi
                ;;
            file)
                if [ -e "$target" ]; then
                    # Verificar se conteúdo é idêntico (sha256)
                    local sha_src sha_dst
                    sha_src="$(sha256sum "$staging/$rel" | awk '{print $1}')"
                    sha_dst="$(sha256sum "$target"       | awk '{print $1}')"
                    if [ "$sha_src" = "$sha_dst" ]; then
                        adm_info "Arquivo já existente e idêntico (mantendo host): $target"
                        continue
                    fi
                    adm_die "Conflito: arquivo $target já existe e difere do que seria instalado."
                fi
                adm_info "Instalando arquivo: $target"
                adm_ensure_dir "$(dirname "$target")"
                if ! cp -a "$staging/$rel" "$target"; then
                    adm_die "Falha ao copiar $staging/$rel -> $target"
                fi
                ;;
        esac
    done <<< "$list"
}

adm_install_generate_files_list() {
    local staging="${1:-}" root="${2:-/}"

    [ -d "$staging" ] || adm_die "adm_install_generate_files_list requer staging válido"

    root="$(adm_install_root_normalize "$root")"

    local list
    list="$(cd "$staging" && find . -mindepth 1 -type f -o -type l -o -type d -print | sort)"

    local entry rel
    while IFS= read -r entry || [ -n "$entry" ]; do
        [ -z "$entry" ] && continue
        rel="${entry#./}"
        [ -z "$rel" ] && continue
        # Caminho "final" (na visão do root); armazenamos com /rel
        printf '/%s\n' "$rel"
    done <<< "$list"
}

adm_install_write_manifest() {
    local category="${1:-}" name="${2:-}" version="${3:-}" root="${4:-/}" files_list_path="${5:-}"

    [ -z "$category" ] && adm_die "adm_install_write_manifest requer categoria"
    [ -z "$name" ]     && adm_die "adm_install_write_manifest requer nome"
    [ -z "$version" ]  && adm_die "adm_install_write_manifest requer versao"
    [ -z "$files_list_path" ] && adm_die "adm_install_write_manifest requer caminho de files.list"

    local dbdir manifest
    dbdir="$(adm_install_pkg_db_dir "$category" "$name" "$version" "$root")"
    adm_ensure_dir "$dbdir"
    manifest="$dbdir/manifest"

    local now
    now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    adm_meta_load "$category" "$name"
    local desc homepage maint
    desc="$(adm_meta_get_var "description")"
    homepage="$(adm_meta_get_var "homepage")"
    maint="$(adm_meta_get_var "maintainer")"

    {
        printf 'name=%s\n' "$name"
        printf 'version=%s\n' "$version"
        printf 'category=%s\n' "$category"
        printf 'root=%s\n' "$(adm_install_root_normalize "$root")"
        printf 'installed_at=%s\n' "$now"
        printf 'description=%s\n' "${desc:-}"
        printf 'homepage=%s\n' "${homepage:-}"
        printf 'maintainer=%s\n' "${maint:-}"
        printf 'adm_db_version=%s\n' "1"
    } >"$manifest"

    adm_info "Manifest criado: $manifest"
    adm_info "files.list:      $files_list_path"
}

# ----------------------------------------------------------------------
# Instalação de um pacote (apenas este, sem resolver deps aqui dentro)
# ----------------------------------------------------------------------

adm_pkg_install_one() {
    local category_raw="${1:-}" name_raw="${2:-}" mode_raw="${3:-build}" root_raw="${4:-/}"

    [ -z "$category_raw" ] && adm_die "adm_pkg_install_one requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_pkg_install_one requer nome"

    local category name mode root version
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"
    mode="$mode_raw"
    root="$(adm_install_root_normalize "$root_raw")"

    adm_install_require_root_if_needed "$root"

    version="$(adm_build_get_version "$category" "$name")"

    if adm_install_pkg_is_installed "$category" "$name" "$version" "$root"; then
        adm_warn "Pacote $category/$name-$version já registrado como instalado em root=$root; pulando reinstalação."
        return 0
    fi

    adm_stage "INSTALL $category/$name-$version (mode=$mode, root=$root)"

    local staging
    staging="$(adm_install_build_to_staging "$category" "$name" "$mode")"

    adm_install_copy_staging_to_root "$staging" "$root"

    # Gerar files.list
    local files_tmp files_final
    files_tmp="$(mktemp "${TMPDIR:-/tmp}/adm-files.XXXXXX")"
    adm_install_generate_files_list "$staging" "$root" >"$files_tmp"

    files_final="$(adm_install_pkg_files_list_path "$category" "$name" "$version" "$root")"
    adm_ensure_dir "$(dirname "$files_final")"
    mv -f "$files_tmp" "$files_final"

    # Manifest
    adm_install_write_manifest "$category" "$name" "$version" "$root" "$files_final"

    adm_info "Instalação concluída: $category/$name-$version em root=$root"

    # Limpa staging
    adm_info "Limpando staging: $staging"
    rm -rf --one-file-system "$staging" || adm_warn "Falha ao remover staging $staging (limpe manualmente)."
}

adm_pkg_install() {
    # Instala pacote + deps, usando build-engine (que já resolve deps).
    #
    # Aqui, deliberadamente deixamos a resolução de deps para o build-engine:
    # ele mesmo chama 32-resolver-deps e constrói dependências na ordem correta,
    # mas cada pacote é instalado via staging + cópia para root por este script.
    #
    # Para manter o fluxo simples e consistente, chamamos adm_pkg_install_one
    # para o pacote alvo, e deixamos as dependências serem construídas/instaladas
    # normal (compartilham o mesmo root ou rootfs).
    #
    # Se quiser instalar "deps+alvo" todos registrados no DB, o ideal é chamar
    # adm_pkg_install_one para cada pacote na ordem topológica. Para isso,
    # usamos 32-resolver-deps se disponível.
    #
    local category_raw="${1:-}" name_raw="${2:-}" mode_raw="${3:-build}" root_raw="${4:-/}"

    [ -z "$category_raw" ] && adm_die "adm_pkg_install requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_pkg_install requer nome"

    local category name mode root
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"
    mode="$mode_raw"
    root="$(adm_install_root_normalize "$root_raw")"

    adm_install_require_root_if_needed "$root"

    # Se tivermos resolver de deps, instalamos todos (deps+alvo) via staging/DB.
    if declare -F adm_deps_resolve_for_pkg >/dev/null 2>&1; then
        adm_stage "RESOLVE-DEPS-INSTALL $category/$name (mode=$mode)"

        local dep_mode
        case "$mode" in
            run)   dep_mode="run" ;;
            all)   dep_mode="all" ;;
            *)     dep_mode="build" ;;
        esac

        local pairs=()
        while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            pairs+=("$line")
        done < <(adm_deps_resolve_for_pkg "$category" "$name" "$dep_mode")

        local p catg pkg
        for p in "${pairs[@]}"; do
            catg="${p%% *}"
            pkg="${p#* }"
            adm_pkg_install_one "$catg" "$pkg" "$mode" "$root"
        done
    else
        # Sem resolver, apenas o alvo principal
        adm_pkg_install_one "$category" "$name" "$mode" "$root"
    fi
}

adm_pkg_install_from_token() {
    local token="${1:-}" mode="${2:-build}" root="${3:-/}"
    [ -z "$token" ] && adm_die "adm_pkg_install_from_token requer token"

    local pair category name
    pair="$(adm_install_parse_token "$token")"
    category="${pair%% *}"
    name="${pair#* }"

    adm_pkg_install "$category" "$name" "$mode" "$root"
}

# ----------------------------------------------------------------------
# Remoção de pacotes
# ----------------------------------------------------------------------

adm_pkg_remove_version() {
    local category_raw="${1:-}" name_raw="${2:-}" version="${3:-}" root_raw="${4:-/}"

    [ -z "$category_raw" ] && adm_die "adm_pkg_remove_version requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_pkg_remove_version requer nome"
    [ -z "$version" ]      && adm_die "adm_pkg_remove_version requer versao"

    local category name root
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"
    root="$(adm_install_root_normalize "$root_raw")"

    adm_install_require_root_if_needed "$root"

    local dbdir files file
    dbdir="$(adm_install_pkg_db_dir "$category" "$name" "$version" "$root")"
    if [ ! -d "$dbdir" ]; then
        adm_die "Pacote $category/$name-$version não está registrado como instalado em root=$root."
    fi

    local files_list
    files_list="$dbdir/files.list"
    if [ ! -f "$files_list" ]; then
        adm_die "files.list não encontrado para $category/$name-$version (root=$root). DB corrompido?"
    fi

    adm_stage "REMOVE $category/$name-$version (root=$root)"

    # Remover arquivos / links
    while IFS= read -r file || [ -n "$file" ]; do
        [ -z "$file" ] && continue
        # file é caminho absoluto na visão do root; mas root pode não ser "/"
        # Logo, path real é root + (file sem o / inicial)
        local rel real_path
        case "$file" in
            /*) rel="${file#/}" ;;
            *)  rel="$file" ;;
        esac
        real_path="$root/$rel"

        if [ -L "$real_path" ] || [ -f "$real_path" ]; then
            adm_info "Removendo arquivo: $real_path"
            if ! rm -f "$real_path"; then
                adm_die "Falha ao remover arquivo: $real_path"
            fi
        elif [ -d "$real_path" ]; then
            # Diretórios: tentaremos limpar depois, em ordem reversa
            :
        else
            adm_warn "Arquivo registrado não existe mais: $real_path (ignorando)."
        fi
    done <"$files_list"

    # Tentar remover diretórios vazios (ordem reversa, caminho mais profundo primeiro)
    # Usamos a mesma files.list para descobrir dirs candidatos.
    local dirs=()
    while IFS= read -r file || [ -n "$file" ]; do
        [ -z "$file" ] && continue
        local rel real_path d
        case "$file" in
            /*) rel="${file#/}" ;;
            *)  rel="$file" ;;
        esac
        real_path="$root/$rel"

        # Adicionar todos diretórios ao longo do caminho
        d="$real_path"
        while [ "$d" != "$root" ] && [ "$d" != "/" ]; do
            dirs+=("$d")
            d="$(dirname "$d")"
        done
    done <"$files_list"

    # Remover duplicatas e ordenar por profundidade decrescente
    if [ "${#dirs[@]}" -gt 0 ]; then
        local uniq
        uniq="$(printf '%s\n' "${dirs[@]}" | awk 'NF && !seen[$0]++' | awk '{print length, $0}' | sort -rn | cut -d" " -f2-)"
        while IFS= read -r d || [ -n "$d" ]; do
            [ -z "$d" ] && continue
            if [ -d "$d" ]; then
                if rmdir "$d" 2>/dev/null; then
                    adm_info "Removido diretório vazio: $d"
                fi
            fi
        done <<< "$uniq"
    fi

    # Remover DB desse pacote/versão
    adm_info "Removendo DB de instalação: $dbdir"
    if ! rm -rf --one-file-system "$dbdir"; then
        adm_die "Falha ao remover diretório de DB: $dbdir"
    fi

    adm_info "Remoção concluída: $category/$name-$version (root=$root)"
}

adm_pkg_remove() {
    local category_raw="${1:-}" name_raw="${2:-}" root_raw="${3:-/}"

    [ -z "$category_raw" ] && adm_die "adm_pkg_remove requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_pkg_remove requer nome"

    local category name root
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"
    root="$(adm_install_root_normalize "$root_raw")"

    local versions
    versions="$(adm_install_list_versions_for_pkg "$category" "$name" "$root")"

    if [ -z "$versions" ]; then
        adm_die "Pacote $category/$name não está instalado em root=$root."
    fi

    # Por enquanto, removemos TODAS as versões instaladas (pode ser refinado no futuro)
    local v
    while IFS= read -r v || [ -n "$v" ]; do
        [ -z "$v" ] && continue
        adm_pkg_remove_version "$category" "$name" "$v" "$root"
    done <<< "$versions"
}

adm_pkg_remove_from_token() {
    local token="${1:-}" root="${2:-/}"
    [ -z "$token" ] && adm_die "adm_pkg_remove_from_token requer token"

    local pair category name
    pair="$(adm_install_parse_token "$token")"
    category="${pair%% *}"
    name="${pair#* }"

    adm_pkg_remove "$category" "$name" "$root"
}

# ----------------------------------------------------------------------
# Listagem e query
# ----------------------------------------------------------------------

adm_pkg_list_installed() {
    local root="${1:-/}"
    root="$(adm_install_root_normalize "$root")"

    local lines
    lines="$(adm_install_list_pkgs_for_root "$root")"
    if [ -z "$lines" ]; then
        adm_info "Nenhum pacote registrado como instalado em root=$root."
        return 0
    fi

    printf '%s\n' "$lines"
}

adm_pkg_query() {
    local category_raw="${1:-}" name_raw="${2:-}" root_raw="${3:-/}"

    [ -z "$category_raw" ] && adm_die "adm_pkg_query requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_pkg_query requer nome"

    local category name root
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"
    root="$(adm_install_root_normalize "$root_raw")"

    local versions
    versions="$(adm_install_list_versions_for_pkg "$category" "$name" "$root")"

    if [ -z "$versions" ]; then
        adm_info "Pacote $category/$name não está instalado em root=$root."
        return 0
    fi

    adm_info "Pacote(s) $category/$name instalado(s) em root=$root:"
    local v
    while IFS= read -r v || [ -n "$v" ]; do
        [ -z "$v" ] && continue
        local dbdir manifest
        dbdir="$(adm_install_pkg_db_dir "$category" "$name" "$v" "$root")"
        manifest="$dbdir/manifest"
        printf "  - %s/%s-%s (db=%s)\n" "$category" "$name" "$v" "$dbdir"
        if [ -f "$manifest" ]; then
            # Mostra algumas linhas do manifest
            sed -n '1,6p' "$manifest" | sed 's/^/      /'
        fi
    done <<< "$versions"
}

# ----------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------

adm_install_usage() {
    cat <<EOF
Uso: $(basename "$0") <comando> [args...]

Comandos:
  install <categoria> <nome> [modo] [root]
      - Instala pacote + dependências, registrando no DB.
      - modo: build (padrão), run, all, stage1, stage2, native.
      - root: diretório alvo (padrão: /).

  install-token <token> [modo] [root]
      - token: "cat/pkg" ou apenas "pkg".

  remove <categoria> <nome> [root]
      - Remove TODAS as versões instaladas de categoria/nome em root.

  remove-token <token> [root]
      - token: "cat/pkg" ou apenas "pkg".

  list [root]
      - Lista todos pacotes registrados em root.

  query <categoria> <nome> [root]
      - Mostra versões instaladas e manifest resumido.

  help
      - Mostra esta ajuda.

Exemplos:
  $(basename "$0") install sys bash build /
  $(basename "$0") install dev gcc build /usr/src/adm/rootfs-stage1
  $(basename "$0") install-token bash all /
  $(basename "$0") remove sys bash /
  $(basename "$0") list /
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-help}"
    case "$cmd" in
        install)
            if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
                adm_error "Uso: $0 install <categoria> <nome> [modo] [root]"
                exit 1
            fi
            catg="$2"
            pkg="$3"
            mode="${4:-build}"
            root="${5:-/}"
            adm_pkg_install "$catg" "$pkg" "$mode" "$root"
            ;;
        install-token)
            if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
                adm_error "Uso: $0 install-token <token> [modo] [root]"
                exit 1
            fi
            token="$2"
            mode="${3:-build}"
            root="${4:-/}"
            adm_pkg_install_from_token "$token" "$mode" "$root"
            ;;
        remove)
            if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
                adm_error "Uso: $0 remove <categoria> <nome> [root]"
                exit 1
            fi
            catg="$2"
            pkg="$3"
            root="${4:-/}"
            adm_pkg_remove "$catg" "$pkg" "$root"
            ;;
        remove-token)
            if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
                adm_error "Uso: $0 remove-token <token> [root]"
                exit 1
            fi
            token="$2"
            root="${3:-/}"
            adm_pkg_remove_from_token "$token" "$root"
            ;;
        list)
            if [ "$#" -gt 2 ]; then
                adm_error "Uso: $0 list [root]"
                exit 1
            fi
            root="${2:-/}"
            adm_pkg_list_installed "$root"
            ;;
        query)
            if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
                adm_error "Uso: $0 query <categoria> <nome> [root]"
                exit 1
            fi
            catg="$2"
            pkg="$3"
            root="${4:-/}"
            adm_pkg_query "$catg" "$pkg" "$root"
            ;;
        help|-h|--help)
            adm_install_usage
            ;;
        *)
            adm_error "Comando desconhecido: $cmd"
            adm_install_usage
            exit 1
            ;;
    esac
fi
