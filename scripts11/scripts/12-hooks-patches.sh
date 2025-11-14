#!/usr/bin/env bash
# 12-hooks-patches.sh
# Gerenciamento de hooks e patches do ADM.
#
# Layout esperado por pacote:
#   /usr/src/adm/repo/<categoria>/<programa>/
#       metafile
#       hook        (arquivo opcional)
#       hook.d/     (diretório opcional, com scripts por estágio)
#           pre_build
#           post_build
#           pre_install
#           post_install
#           ...
#       patch/      (diretório opcional com *.patch)
#
# Estágios suportados (nomes recomendados):
#   pre_fetch, post_fetch
#   pre_patch, post_patch
#   pre_configure, post_configure
#   pre_build, post_build
#   pre_install, post_install
#   pre_test, post_test
#
# O hook recebe variáveis de ambiente:
#   ADM_HOOK_STAGE       : nome do estágio (pre_build, post_build, ...)
#   ADM_HOOK_CATEGORY    : categoria do pacote
#   ADM_HOOK_NAME        : nome do pacote
#   ADM_HOOK_VERSION     : versão (se disponível via ADM_META_version)
#   ADM_HOOK_PROFILE     : profile ativo (ADM_PROFILE)
#   ADM_HOOK_WORKDIR     : diretório de trabalho (workdir)
#   ADM_HOOK_DESTDIR     : diretório DESTDIR (se existir)
#   ADM_HOOK_REPO_DIR    : dir do pacote no repo
#   ADM_HOOK_PATCH_DIR   : dir de patches
#
# Patches:
#   - Todos os arquivos *.patch em patch/ são aplicados em ordem de nome
#     usando "patch -p1 --forward --batch".
#   - Falha em aplicar patch aborta (sem erro silencioso).
# ----------------------------------------------------------------------
# Requisitos e modo seguro
# ----------------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 12-hooks-patches.sh requer bash." >&2
    exit 1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERRO: 12-hooks-patches.sh requer bash >= 4." >&2
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
# Logging: usa 01-log-ui.sh se disponível, senão fallback simples
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

# Se tivermos funções de repo do 10-repo-metafile.sh, usamos; senão criamos compatibilidade.
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

if ! declare -F adm_repo_pkg_base_dir >/dev/null 2>&1; then
    adm_repo_pkg_base_dir() {
        local category_raw="${1:-}"
        local name_raw="${2:-}"
        local category name
        category="$(adm_repo_sanitize_category "$category_raw")"
        name="$(adm_repo_sanitize_name "$name_raw")"
        printf '%s/%s/%s' "$ADM_REPO" "$category" "$name"
    }
fi

if ! declare -F adm_repo_pkg_hook_path >/dev/null 2>&1; then
    adm_repo_pkg_hook_path() {
        local category="${1:-}"
        local name="${2:-}"
        local base
        base="$(adm_repo_pkg_base_dir "$category" "$name")"
        printf '%s/hook' "$base"
    }
fi

if ! declare -F adm_repo_pkg_patch_dir >/dev/null 2>&1; then
    adm_repo_pkg_patch_dir() {
        local category="${1:-}"
        local name="${2:-}"
        local base
        base="$(adm_repo_pkg_base_dir "$category" "$name")"
        printf '%s/patch' "$base"
    }
fi

# ----------------------------------------------------------------------
# Estágios conhecidos
# ----------------------------------------------------------------------

ADM_HOOK_KNOWN_STAGES=(
    pre_fetch  post_fetch
    pre_patch  post_patch
    pre_configure post_configure
    pre_build  post_build
    pre_install post_install
    pre_test   post_test
)

adm_hook_stage_normalize() {
    # Aceita "pos_build" como alias para "post_build" (mitigando erros de digitação comuns).
    local stage="${1:-}"
    case "$stage" in
        pos_build)   printf '%s' "post_build" ;;
        pos_install) printf '%s' "post_install" ;;
        pos_test)    printf '%s' "post_test" ;;
        *)           printf '%s' "$stage" ;;
    esac
}

adm_hook_stage_is_known() {
    local stage_raw="${1:-}"
    local stage
    stage="$(adm_hook_stage_normalize "$stage_raw")"
    local s
    for s in "${ADM_HOOK_KNOWN_STAGES[@]}"; do
        if [ "$s" = "$stage" ]; then
            return 0
        fi
    done
    return 1
}

# ----------------------------------------------------------------------
# Descoberta de arquivos de hook
# ----------------------------------------------------------------------

adm_hooks_pkg_dir() {
    local category="${1:-}"
    local name="${2:-}"
    adm_repo_pkg_base_dir "$category" "$name"
}

adm_hooks_hook_file() {
    # Arquivo 'hook' do pacote
    local category="${1:-}"
    local name="${2:-}"
    adm_repo_pkg_hook_path "$category" "$name"
}

adm_hooks_hook_d_dir() {
    # Diretório hook.d do pacote
    local category="${1:-}"
    local name="${2:-}"
    local base
    base="$(adm_repo_pkg_base_dir "$category" "$name")"
    printf '%s/hook.d' "$base"
}

adm_hooks_stage_specific_file() {
    # hook.d/<stage> se existir.
    local category="${1:-}"
    local name="${2:-}"
    local stage_raw="${3:-}"
    local stage
    stage="$(adm_hook_stage_normalize "$stage_raw")"

    local d
    d="$(adm_hooks_hook_d_dir "$category" "$name")"
    printf '%s/%s' "$d" "$stage"
}

# ----------------------------------------------------------------------
# Execução de hooks
# ----------------------------------------------------------------------

adm_hooks_run_one() {
    # Executa um arquivo de hook específico, se existir e for executável.
    # Não chama se o arquivo não existir.
    # Abortamos se o hook retornar código != 0.
    local hook_path="${1:-}"

    if [ -z "$hook_path" ]; then
        adm_die "adm_hooks_run_one chamado com hook_path vazio"
    fi

    if [ ! -e "$hook_path" ]; then
        # silencioso: o chamador decide se isso é ok (não é erro não ter um hook)
        return 0
    fi

    if [ ! -f "$hook_path" ]; then
        adm_die "Hook existe, mas não é arquivo regular: $hook_path"
    fi

    if [ ! -x "$hook_path" ]; then
        # Tenta deixar executável; se falhar, ainda tentamos executá-lo via bash.
        chmod +x "$hook_path" 2>/dev/null || true
    fi

    adm_info "Executando hook: $hook_path (stage=${ADM_HOOK_STAGE:-<desconhecido>})"

    # Executar em subshell para evitar poluir ambiente
    if ! ( "$hook_path" ); then
        local rc=$?
        adm_die "Hook '$hook_path' falhou (rc=$rc)"
    fi
}

adm_hooks_run_stage() {
    # API principal para rodar hooks de um pacote em um determinado estágio.
    #
    # Uso:
    #   adm_hooks_run_stage categoria nome stage workdir destdir
    #
    # workdir/destdir são opcionais, mas recomendados.
    local category_raw="${1:-}"
    local name_raw="${2:-}"
    local stage_raw="${3:-}"
    local workdir="${4:-}"
    local destdir="${5:-}"

    [ -z "$category_raw" ] && adm_die "adm_hooks_run_stage requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_hooks_run_stage requer nome"
    [ -z "$stage_raw" ]    && adm_die "adm_hooks_run_stage requer stage"

    local category name stage
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"
    stage="$(adm_hook_stage_normalize "$stage_raw")"

    # Checagem de stage
    if ! adm_hook_stage_is_known "$stage"; then
        adm_warn "Stage de hook desconhecido: '$stage' (continuando mesmo assim)"
    fi

    # Descobrir paths
    local pkg_dir repo_dir hook_file hook_d_file patch_dir
    pkg_dir="$(adm_repo_pkg_base_dir "$category" "$name")"
    repo_dir="$pkg_dir"
    hook_file="$(adm_hooks_hook_file "$category" "$name")"
    hook_d_file="$(adm_hooks_stage_specific_file "$category" "$name" "$stage")"
    patch_dir="$(adm_repo_pkg_patch_dir "$category" "$name")"

    # Versão (se disponível via ADM_META_version ou adm_meta_get_var)
    local version=""
    if [ -n "${ADM_META_version-}" ]; then
        version="$ADM_META_version"
    elif declare -F adm_meta_get_var >/dev/null 2>&1; then
        # Tenta ler do metafile
        set +e
        version="$(adm_meta_get_var "version" 2>/dev/null || echo "")"
        set -e
    fi

    # Profile ativo, se houver
    local profile="${ADM_PROFILE:-}"

    # Prepara variáveis de ambiente para o hook
    export ADM_HOOK_STAGE="$stage"
    export ADM_HOOK_CATEGORY="$category"
    export ADM_HOOK_NAME="$name"
    export ADM_HOOK_VERSION="$version"
    export ADM_HOOK_PROFILE="$profile"
    export ADM_HOOK_WORKDIR="$workdir"
    export ADM_HOOK_DESTDIR="$destdir"
    export ADM_HOOK_REPO_DIR="$repo_dir"
    export ADM_HOOK_PATCH_DIR="$patch_dir"

    # 1) hook.d/<stage> tem prioridade
    if [ -f "$hook_d_file" ]; then
        adm_hooks_run_one "$hook_d_file"
        return 0
    fi

    # 2) arquivo único 'hook', se existir
    if [ -f "$hook_file" ]; then
        adm_hooks_run_one "$hook_file"
        return 0
    fi

    # 3) nenhum hook -> não é erro
    adm_info "Nenhum hook encontrado para '$category/$name' (stage=$stage)."
    return 0
}

# ----------------------------------------------------------------------
# Patches
# ----------------------------------------------------------------------

ADM_PATCH_PLEVEL_DEFAULT="${ADM_PATCH_PLEVEL_DEFAULT:-1}"

adm_patches_apply_all() {
    # Aplica todos os patches (*.patch) para o pacote em um diretório de trabalho.
    #
    # Uso:
    #   adm_patches_apply_all categoria nome workdir
    #
    local category_raw="${1:-}"
    local name_raw="${2:-}"
    local workdir="${3:-}"

    [ -z "$category_raw" ] && adm_die "adm_patches_apply_all requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_patches_apply_all requer nome"
    [ -z "$workdir" ]      && adm_die "adm_patches_apply_all requer workdir"

    if [ ! -d "$workdir" ]; then
        adm_die "Diretório de trabalho inválido para patches: $workdir"
    fi

    local category name patch_dir
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"
    patch_dir="$(adm_repo_pkg_patch_dir "$category" "$name")"

    if [ ! -d "$patch_dir" ]; then
        adm_info "Nenhum diretório de patches para '$category/$name' (não aplicando patches)."
        return 0
    fi

    local patches_found=0
    local p
    shopt -s nullglob
    local patch_list=("$patch_dir"/*.patch)
    shopt -u nullglob

    if [ "${#patch_list[@]}" -eq 0 ]; then
        adm_info "Diretório de patches está vazio para '$category/$name'."
        return 0
    fi

    adm_info "Aplicando patches para '$category/$name' em '$workdir'..."

    for p in "${patch_list[@]}"; do
        [ -f "$p" ] || continue
        patches_found=1
        adm_info "Aplicando patch: $p"
        (
            cd "$workdir" || exit 1
            # Usando --forward para evitar reaplicar patch já aplicado.
            # --batch para não perguntar nada.
            if ! patch -p"${ADM_PATCH_PLEVEL_DEFAULT}" --forward --batch <"$p"; then
                adm_die "Falha ao aplicar patch '$p' em '$workdir'"
            fi
        )
    done

    if [ "$patches_found" -eq 0 ]; then
        adm_info "Nenhum arquivo *.patch encontrado no diretório de patches para '$category/$name'."
    else
        adm_info "Todos os patches aplicados com sucesso para '$category/$name'."
    fi
}

# ----------------------------------------------------------------------
# Atalhos combinados: hooks + patches
# ----------------------------------------------------------------------

adm_hooks_and_patches_for_stage() {
    # Conveniência: roda hooks de estágio e/ou aplica patches quando apropriado.
    #
    # Uso típico:
    #   adm_hooks_and_patches_for_stage categoria nome pre_patch workdir
    #
    # Se stage for pre_patch ou post_patch, faz sentido aplicar patches
    # ou rodar hooks relacionados. Aqui apenas automatizamos 2 coisas:
    #
    #   - pre_patch  -> roda hooks stage=pre_patch, depois aplica patches
    #   - post_patch -> roda hooks stage=post_patch (após patches)
    #
    local category="${1:-}"
    local name="${2:-}"
    local stage_raw="${3:-}"
    local workdir="${4:-}"
    local destdir="${5:-}"

    [ -z "$category" ] && adm_die "adm_hooks_and_patches_for_stage requer categoria"
    [ -z "$name" ]     && adm_die "adm_hooks_and_patches_for_stage requer nome"
    [ -z "$stage_raw" ] && adm_die "adm_hooks_and_patches_for_stage requer stage"

    local stage
    stage="$(adm_hook_stage_normalize "$stage_raw")"

    case "$stage" in
        pre_patch)
            # Hooks de pre_patch antes de aplicar patches
            adm_hooks_run_stage "$category" "$name" "pre_patch" "$workdir" "$destdir"
            adm_patches_apply_all "$category" "$name" "$workdir"
            ;;
        post_patch)
            # Patches já devem ter sido aplicados; apenas hooks.
            adm_hooks_run_stage "$category" "$name" "post_patch" "$workdir" "$destdir"
            ;;
        *)
            # Para outros estágios, apenas delega para hooks.
            adm_hooks_run_stage "$category" "$name" "$stage" "$workdir" "$destdir"
            ;;
    esac
}

# ----------------------------------------------------------------------
# Comportamento ao ser executado diretamente (demo)
# ----------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    adm_info "12-hooks-patches.sh executado diretamente (modo demonstração)."
    adm_info "Este script é pensado para ser 'sourced' por outros componentes do ADM."
    echo
    echo "Funções principais disponíveis:"
    echo "  adm_hooks_run_stage categoria nome stage [workdir] [destdir]"
    echo "  adm_patches_apply_all categoria nome workdir"
    echo "  adm_hooks_and_patches_for_stage categoria nome stage [workdir] [destdir]"
fi
