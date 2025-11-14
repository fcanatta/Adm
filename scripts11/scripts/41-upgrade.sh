#!/usr/bin/env bash
# 41-upgrade.sh
# Gerenciador de UPGRADE do ADM – super evoluído e inteligente.
#
# Integra com:
#   - 10-repo-metafile.sh    (formato do metafile de repo)
#   - 33-install-remove.sh   (instalação real do pacote)
#   - 40-update-manager.sh   (metafiles gerados em ADM_UPDATE_ROOT)
#   - 32-resolver-deps.sh    (opcional, para deep upgrade)
#
# Função principal:
#   - Ler updates preparados em:
#       $ADM_UPDATE_ROOT/<categoria>/<nome>/metafile
#   - Comparar com o metafile atual do repo:
#       $ADM_REPO/<categoria>/<nome>/metafile
#   - Se versão de update for maior:
#       * Fazer backup dos artefatos atuais do repo (metafile/hook/patch)
#       * Aplicar metafile/patch/hook de update no repo
#       * Opcionalmente chamar 33-install-remove.sh para instalar a nova versão
#   - Pode operar:
#       * Em um único pacote
#       * Em um token (cat/pkg ou pkg)
#       * Em todos os pacotes que têm updates pendentes (world)
#       * Opcionalmente em modo "deep", usando grafo de deps (se 32-resolver estiver disponível)
#
# Nenhum erro silencioso: qualquer falha crítica chama adm_die com mensagem clara.

# ----------------------------------------------------------------------
# Requisitos básicos
# ----------------------------------------------------------------------

if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 41-upgrade.sh requer bash." >&2
    exit 1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERRO: 41-upgrade.sh requer bash >= 4." >&2
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------
# Ambiente e logging
# ----------------------------------------------------------------------

ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"
ADM_REPO="${ADM_REPO:-$ADM_ROOT/repo}"
ADM_UPDATE_ROOT="${ADM_UPDATE_ROOT:-$ADM_ROOT/update}"
ADM_SCRIPTS="${ADM_SCRIPTS:-$ADM_ROOT/scripts}"

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

# Sanitizadores (compatíveis com 10-repo-metafile)
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

# Resolver de deps (deep upgrade) – opcional
ADM_UPGRADE_HAS_DEPS=0
if declare -F adm_deps_resolve_for_pkg >/dev/null 2>&1 && \
   declare -F adm_deps_parse_token >/dev/null 2>&1; then
    ADM_UPGRADE_HAS_DEPS=1
fi

# ----------------------------------------------------------------------
# Helpers gerais
# ----------------------------------------------------------------------

adm_upgrade_trim() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

adm_upgrade_root_normalize() {
    local root="${1:-/}"
    [ -z "$root" ] && root="/"
    root="$(printf '%s' "$root" | sed 's://*:/:g')"
    printf '%s\n' "$root"
}

adm_upgrade_require_root_if_needed() {
    local root
    root="$(adm_upgrade_root_normalize "${1:-/}")"
    if [ "$root" = "/" ] && [ "$(id -u)" -ne 0 ]; then
        adm_die "Upgrade com root='/' requer privilégios de root."
    fi
}

adm_upgrade_version_compare() {
    # Compara v1 e v2 usando sort -V:
    #   -1 => v1 < v2
    #    0 => igual
    #    1 => v1 > v2
    local v1="${1:-}" v2="${2:-}"

    if [ "$v1" = "$v2" ]; then
        printf '0\n'
        return 0
    fi

    local first
    first="$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)"
    if [ "$first" = "$v1" ]; then
        printf '%s\n' "-1"
    else
        printf '%s\n' "1"
    fi
}

adm_upgrade_version_is_newer() {
    # 0 => new > old; 1 caso contrário
    local old="${1:-}" new="${2:-}"
    local cmp
    cmp="$(adm_upgrade_version_compare "$old" "$new")"
    if [ "$cmp" = "-1" ]; then
        return 0
    fi
    return 1
}

adm_upgrade_meta_get_field() {
    # Uso: adm_upgrade_meta_get_field <arquivo> <chave>
    # Retorna o valor (apenas a primeira ocorrência).
    local file="${1:-}" key="${2:-}"
    [ -z "$file" ] && adm_die "adm_upgrade_meta_get_field requer arquivo"
    [ -z "$key" ]  && adm_die "adm_upgrade_meta_get_field requer chave"
    if [ ! -f "$file" ]; then
        adm_die "Metafile inexistente: $file"
    fi
    sed -n "s/^${key}=\(.*\)$/\1/p" "$file" | head -n1
}

adm_upgrade_meta_path_repo() {
    local category="${1:-}" name="${2:-}"
    category="$(adm_repo_sanitize_category "$category")"
    name="$(adm_repo_sanitize_name "$name")"
    printf '%s/%s/%s/metafile' "$ADM_REPO" "$category" "$name"
}

adm_upgrade_meta_path_update() {
    local category="${1:-}" name="${2:-}"
    category="$(adm_repo_sanitize_category "$category")"
    name="$(adm_repo_sanitize_name "$name")"
    printf '%s/%s/%s/metafile' "$ADM_UPDATE_ROOT" "$category" "$name"
}

adm_upgrade_hook_path_repo() {
    local category="${1:-}" name="${2:-}"
    printf '%s/%s/%s/hook' "$ADM_REPO" "$category" "$name"
}

adm_upgrade_hook_path_update() {
    local category="${1:-}" name="${2:-}"
    printf '%s/%s/%s/hook' "$ADM_UPDATE_ROOT" "$category" "$name"
}

adm_upgrade_patch_dir_repo() {
    local category="${1:-}" name="${2:-}"
    printf '%s/%s/%s/patch' "$ADM_REPO" "$category" "$name"
}

adm_upgrade_patch_dir_update() {
    local category="${1:-}" name="${2:-}"
    printf '%s/%s/%s/patch' "$ADM_UPDATE_ROOT" "$category" "$name"
}

adm_upgrade_backup_dir() {
    local category="${1:-}" name="${2:-}" old_version="${3:-}"
    local ts
    ts="$(date -u +"%Y%m%dT%H%M%SZ")"
    printf '%s/%s/%s/backup-%s-%s' "$ADM_UPDATE_ROOT" "$category" "$name" "$old_version" "$ts"
}

# ----------------------------------------------------------------------
# Chamada à instalação real (33-install-remove.sh)
# ----------------------------------------------------------------------

adm_upgrade_call_install() {
    local category="${1:-}" name="${2:-}" root="${3:-/}"
    category="$(adm_repo_sanitize_category "$category")"
    name="$(adm_repo_sanitize_name "$name")"
    root="$(adm_upgrade_root_normalize "$root")"

    adm_upgrade_require_root_if_needed "$root"

    local script="$ADM_SCRIPTS/33-install-remove.sh"
    if [ ! -x "$script" ]; then
        adm_die "Script de instalação não encontrado ou não executável: $script"
    fi

    adm_stage "INSTALL new version $category/$name (root=$root)"

    "$script" install "$category" "$name" "build" "$root"
}

# ----------------------------------------------------------------------
# Upgrade de um único pacote (apenas ele)
# ----------------------------------------------------------------------

adm_upgrade_one_pkg() {
    local category_raw="${1:-}" name_raw="${2:-}" root_raw="${3:-/}" no_install="${4:-0}"

    [ -z "$category_raw" ] && adm_die "adm_upgrade_one_pkg requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_upgrade_one_pkg requer nome"

    local category name root
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"
    root="$(adm_upgrade_root_normalize "$root_raw")"

    adm_stage "UPGRADE $category/$name (root=$root, no_install=$no_install)"

    local repo_meta update_meta
    repo_meta="$(adm_upgrade_meta_path_repo "$category" "$name")"
    update_meta="$(adm_upgrade_meta_path_update "$category" "$name")"

    if [ ! -f "$repo_meta" ]; then
        adm_die "Metafile do repo não encontrado para $category/$name: $repo_meta"
    fi

    if [ ! -f "$update_meta" ]; then
        adm_info "Nenhum metafile de update para $category/$name em $update_meta; nada a fazer."
        return 0
    fi

    local cur_version new_version
    cur_version="$(adm_upgrade_meta_get_field "$repo_meta" "version")"
    new_version="$(adm_upgrade_meta_get_field "$update_meta" "version")"

    if [ -z "$cur_version" ]; then
        adm_die "Metafile do repo de $category/$name não contém 'version'."
    fi
    if [ -z "$new_version" ]; then
        adm_die "Metafile de update de $category/$name não contém 'version'."
    fi

    adm_info "Versão atual: $cur_version"
    adm_info "Versão nova:  $new_version"

    if ! adm_upgrade_version_is_newer "$cur_version" "$new_version"; then
        adm_info "Versão de update ($new_version) não é maior que a atual ($cur_version). Ignorando upgrade."
        return 0
    fi

    local backup_dir
    backup_dir="$(adm_upgrade_backup_dir "$category" "$name" "$cur_version")"
    adm_ensure_dir "$backup_dir"

    adm_info "Diretório de backup: $backup_dir"

    # Backup de metafile/hook/patch do repo
    local repo_hook repo_patch
    repo_hook="$(adm_upgrade_hook_path_repo "$category" "$name")"
    repo_patch="$(adm_upgrade_patch_dir_repo "$category" "$name")"

    if [ -f "$repo_meta" ]; then
        cp -a "$repo_meta" "$backup_dir/metafile-$cur_version" || adm_die "Falha ao fazer backup de $repo_meta"
    fi
    if [ -f "$repo_hook" ]; then
        cp -a "$repo_hook" "$backup_dir/hook-$cur_version" || adm_die "Falha ao fazer backup de $repo_hook"
    fi
    if [ -d "$repo_patch" ]; then
        cp -a "$repo_patch" "$backup_dir/patch-$cur_version" || adm_die "Falha ao fazer backup de $repo_patch"
    fi

    # Aplicar metafile de update ao repo (substitui o antigo)
    cp -a "$update_meta" "$repo_meta" || adm_die "Falha ao copiar $update_meta -> $repo_meta"

    # Tratamento de hook
    local update_hook
    update_hook="$(adm_upgrade_hook_path_update "$category" "$name")"

    if [ -f "$update_hook" ]; then
        if [ -f "$repo_hook" ]; then
            # Já existe hook específico no repo -> não sobrescrever
            adm_warn "Hook de repo já existe ($repo_hook); hook de update será salvo como $repo_hook.new-$new_version"
            cp -a "$update_hook" "$repo_hook.new-$new_version" || adm_die "Falha ao salvar hook de update como .new"
        else
            cp -a "$update_hook" "$repo_hook" || adm_die "Falha ao copiar hook de update para repo"
        fi
    else
        adm_info "Nenhum hook específico em update para $category/$name."
    fi

    # Tratamento de patch
    local update_patch
    update_patch="$(adm_upgrade_patch_dir_update "$category" "$name")"

    if [ -d "$update_patch" ]; then
        # Backup do patch antigo já foi feito acima.
        if [ -d "$repo_patch" ]; then
            rm -rf --one-file-system "$repo_patch" || adm_die "Falha ao remover diretório de patch antigo: $repo_patch"
        fi
        cp -a "$update_patch" "$repo_patch" || adm_die "Falha ao copiar patch de update para repo"
    else
        adm_info "Nenhum diretório de patches em update para $category/$name."
    fi

    adm_info "Metafile/hook/patch de $category/$name atualizados no repo."

    if [ "$no_install" -eq 1 ]; then
        adm_info "no_install=1; não será feita instalação da nova versão."
        return 0
    fi

    # Tentar instalar nova versão
    set +e
    adm_upgrade_call_install "$category" "$name" "$root"
    local rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
        adm_error "Instalação da nova versão de $category/$name falhou (rc=$rc). Iniciando rollback de metafile/hook/patch."
        # Rollback de repo metafile/hook/patch para o backup
        if [ -f "$backup_dir/metafile-$cur_version" ]; then
            cp -a "$backup_dir/metafile-$cur_version" "$repo_meta" || adm_warn "Falha ao restaurar metafile antigo; revise manualmente."
        fi
        if [ -f "$backup_dir/hook-$cur_version" ]; then
            cp -a "$backup_dir/hook-$cur_version" "$repo_hook" || adm_warn "Falha ao restaurar hook antigo; revise manualmente."
        fi
        if [ -d "$backup_dir/patch-$cur_version" ]; then
            rm -rf --one-file-system "$repo_patch" 2>/dev/null || true
            cp -a "$backup_dir/patch-$cur_version" "$repo_patch" || adm_warn "Falha ao restaurar patch antigo; revise manualmente."
        fi
        adm_die "Upgrade de $category/$name não foi concluído; sistema pode ter arquivos parciais instalados. Verifique manualmente."
    fi

    adm_info "Upgrade concluído com sucesso: $category/$name $cur_version -> $new_version (root=$root)"
}

# ----------------------------------------------------------------------
# Deep upgrade (pacote + dependências)
# ----------------------------------------------------------------------

declare -Ag ADM_UPGRADE_VISITED # "cat name" -> 1

adm_upgrade_pkg_id() {
    local c="${1:-}" n="${2:-}"
    printf '%s %s' "$c" "$n"
}

adm_upgrade_deep_one_internal() {
    local category="${1:-}" name="${2:-}" root="${3:-}" no_install="${4:-0}"

    local id
    id="$(adm_upgrade_pkg_id "$category" "$name")"
    if [ "${ADM_UPGRADE_VISITED[$id]+x}" = "x" ]; then
        return 0
    fi
    ADM_UPGRADE_VISITED["$id"]=1

    # Primeiro, deep em dependências, se resolver estiver disponível
    if [ "$ADM_UPGRADE_HAS_DEPS" -eq 1 ]; then
        adm_stage "DEEP-DEPS $category/$name"
        local pairs=()
        while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            pairs+=("$line")
        done < <(adm_deps_resolve_for_pkg "$category" "$name" "all")

        local p catg pkg
        for p in "${pairs[@]}"; do
            catg="${p%% *}"
            pkg="${p#* }"
            # Não reinclui o próprio pacote
            if [ "$catg" = "$category" ] && [ "$pkg" = "$name" ]; then
                continue
            fi
            adm_upgrade_deep_one_internal "$catg" "$pkg" "$root" "$no_install"
        done
    else
        adm_warn "Deep upgrade solicitado, mas resolver de deps não está disponível; atualizando apenas $category/$name."
    fi

    # Agora, upgrade do próprio pacote
    adm_upgrade_one_pkg "$category" "$name" "$root" "$no_install"
}

adm_upgrade_deep_one_pkg() {
    local category="${1:-}" name="${2:-}" root="${3:-/}" no_install="${4:-0}"
    ADM_UPGRADE_VISITED=()
    adm_upgrade_deep_one_internal "$category" "$name" "$root" "$no_install"
}

# ----------------------------------------------------------------------
# Parsing de token (cat/pkg ou pkg)
# ----------------------------------------------------------------------

adm_upgrade_parse_token() {
    local token_raw="${1:-}"
    local token
    token="$(adm_upgrade_trim "$token_raw")"
    if [ -z "$token" ] ; then
        adm_die "adm_upgrade_parse_token chamado com token vazio."
    fi

    if [[ "$token" == */* ]]; then
        local c="${token%%/*}"
        local n="${token#*/}"
        c="$(adm_repo_sanitize_category "$c")"
        n="$(adm_repo_sanitize_name "$n")"
        printf '%s %s\n' "$c" "$n"
        return 0
    fi

    # Sem categoria: procurar no repo
    local name
    name="$(adm_repo_sanitize_name "$token")"
    local matches=() cat_dir pkg_dir cat pkg

    if [ ! -d "$ADM_REPO" ]; then
        adm_die "ADM_REPO não existe: $ADM_REPO (não é possível resolver token '$token')."
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
}

# ----------------------------------------------------------------------
# Upgrade de TODOS os pacotes que têm updates pendentes
# ----------------------------------------------------------------------

adm_upgrade_world() {
    local root="${1:-/}" no_install="${2:-0}" deep="${3:-0}"

    root="$(adm_upgrade_root_normalize "$root")"

    adm_stage "WORLD-UPGRADE (root=$root, no_install=$no_install, deep=$deep)"

    if [ ! -d "$ADM_UPDATE_ROOT" ]; then
        adm_info "Nenhum diretório de update encontrado em $ADM_UPDATE_ROOT; nada a fazer."
        return 0
    fi

    local update_files=()
    local f
    while IFS= read -r f || [ -n "$f" ]; do
        update_files+=("$f")
    done < <(find "$ADM_UPDATE_ROOT" -mindepth 3 -maxdepth 3 -type f -name 'metafile' 2>/dev/null || true)

    if [ "${#update_files[@]}" -eq 0 ]; then
        adm_info "Nenhum metafile de update encontrado em $ADM_UPDATE_ROOT; nada a fazer."
        return 0
    fi

    # Para cada metafile de update, extrair category/name e checar se realmente é upgrade
    local path rel category name repo_meta cur_version new_version
    for path in "${update_files[@]}"; do
        # path: ADM_UPDATE_ROOT/categoria/nome/metafile
        rel="${path#$ADM_UPDATE_ROOT/}"
        category="${rel%%/*}"
        rel="${rel#*/}"
        name="${rel%%/*}"

        repo_meta="$(adm_upgrade_meta_path_repo "$category" "$name")"
        if [ ! -f "$repo_meta" ]; then
            adm_warn "Metafile do repo não encontrado para $category/$name; ignorando update em $path."
            continue
        fi

        cur_version="$(adm_upgrade_meta_get_field "$repo_meta" "version")"
        new_version="$(adm_upgrade_meta_get_field "$path" "version")"

        if [ -z "$cur_version" ] || [ -z "$new_version" ]; then
            adm_warn "Metafile sem versão (repo ou update) para $category/$name; ignorando."
            continue
        fi

        if ! adm_upgrade_version_is_newer "$cur_version" "$new_version"; then
            adm_info "Update para $category/$name ($new_version) não é maior que $cur_version; ignorando."
            continue
        fi

        adm_info "Upgrade pendente detectado: $category/$name $cur_version -> $new_version"

        if [ "$deep" -eq 1 ]; then
            adm_upgrade_deep_one_pkg "$category" "$name" "$root" "$no_install"
        else
            adm_upgrade_one_pkg "$category" "$name" "$root" "$no_install"
        fi
    done
}

# ----------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------

adm_upgrade_usage() {
    cat <<EOF
Uso: $(basename "$0") <comando> [args...]

Comandos:

  upgrade <categoria> <nome> [root] [--no-install] [--deep]
      - Aplica o metafile de update de \$ADM_UPDATE_ROOT/categoria/nome/metafile
        ao repo e, se bem-sucedido, instala a nova versão via 33-install-remove.sh.
      - root: diretório alvo da instalação (padrão: /).
      - --no-install: apenas atualiza metafile/hook/patch no repo, sem instalar.
      - --deep: tenta atualizar também todas as dependências (deep upgrade),
                se o resolver de dependências estiver disponível.

  upgrade-token <token> [root] [--no-install] [--deep]
      - token: "cat/pkg" ou apenas "pkg" (categoria será detectada).

  world [root] [--no-install] [--deep]
      - Varre \$ADM_UPDATE_ROOT procurando updates pendentes
        e os aplica (upgrade de todos os pacotes com nova versão disponível).
      - root: diretório alvo da instalação (padrão: /).
      - --no-install: apenas atualiza metafiles no repo.
      - --deep: deep upgrade para cada pacote (usa 32-resolver-deps, se disponível).

  help
      - Mostra esta ajuda.

Variáveis:
  ADM_ROOT=/usr/src/adm
  ADM_REPO=\$ADM_ROOT/repo
  ADM_UPDATE_ROOT=\$ADM_ROOT/update
  ADM_SCRIPTS=\$ADM_ROOT/scripts

Exemplos:
  $(basename "$0") upgrade sys bash /
  $(basename "$0") upgrade sys bash /usr/src/adm/rootfs-stage2 --no-install
  $(basename "$0") upgrade-token bash / --deep
  $(basename "$0") world /
  $(basename "$0") world / --deep
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-help}"
    case "$cmd" in
        upgrade)
            if [ "$#" -lt 3 ]; then
                adm_error "Uso: $0 upgrade <categoria> <nome> [root] [--no-install] [--deep]"
                exit 1
            fi
            catg="$2"
            pkg="$3"
            root="${4:-/}"
            shift 3
            # Agora $1 é root ou opção
            # Reprocessar flags
            no_install=0
            deep=0
            # Se o próximo não começa com "-", assume que é root
            if [ "${1:-}" != "" ] && [ "${1#-}" != "${1}" ]; then
                : # primeiro argumento extra é opção
            elif [ "${1:-}" != "" ]; then
                root="$1"
                shift
            fi
            while [ "$#" -gt 1 ]; do
                case "$2" in
                    --no-install) no_install=1 ;;
                    --deep)       deep=1 ;;
                    *)
                        adm_error "Opção desconhecida: $2"
                        adm_upgrade_usage
                        exit 1
                        ;;
                esac
                shift
            done
            if [ "$deep" -eq 1 ]; then
                adm_upgrade_deep_one_pkg "$catg" "$pkg" "$root" "$no_install"
            else
                adm_upgrade_one_pkg "$catg" "$pkg" "$root" "$no_install"
            fi
            ;;
        upgrade-token)
            if [ "$#" -lt 2 ]; then
                adm_error "Uso: $0 upgrade-token <token> [root] [--no-install] [--deep]"
                exit 1
            fi
            token="$2"
            root="${3:-/}"
            shift 2
            no_install=0
            deep=0
            # Se o próximo não começa com "-", assume root
            if [ "${1:-}" != "" ] && [ "${1#-}" != "${1}" ]; then
                : # é opção
            elif [ "${1:-}" != "" ]; then
                root="$1"
                shift
            fi
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --no-install) no_install=1 ;;
                    --deep)       deep=1 ;;
                    *)
                        adm_error "Opção desconhecida: $1"
                        adm_upgrade_usage
                        exit 1
                        ;;
                esac
                shift
            done
            pair="$(adm_upgrade_parse_token "$token")"
            catg="${pair%% *}"
            pkg="${pair#* }"
            if [ "$deep" -eq 1 ]; then
                adm_upgrade_deep_one_pkg "$catg" "$pkg" "$root" "$no_install"
            else
                adm_upgrade_one_pkg "$catg" "$pkg" "$root" "$no_install"
            fi
            ;;
        world)
            # world [root] [--no-install] [--deep]
            root="${2:-/}"
            shift 1
            no_install=0
            deep=0
            if [ "${1:-}" != "" ] && [ "${1#-}" != "${1}" ]; then
                : # root default, próxima é opção
            elif [ "${1:-}" != "" ]; then
                root="$1"
                shift
            fi
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --no-install) no_install=1 ;;
                    --deep)       deep=1 ;;
                    *)
                        adm_error "Opção desconhecida: $1"
                        adm_upgrade_usage
                        exit 1
                        ;;
                esac
                shift
            done
            adm_upgrade_world "$root" "$no_install" "$deep"
            ;;
        help|-h|--help)
            adm_upgrade_usage
            ;;
        *)
            adm_error "Comando desconhecido: $cmd"
            adm_upgrade_usage
            exit 1
            ;;
    esac
fi
