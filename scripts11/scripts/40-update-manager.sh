#!/usr/bin/env bash
# 40-update-manager.sh
# Gerenciador de updates do ADM – EXTREMO e inteligente.
#
# Objetivo (de acordo com suas escolhas):
#   1:3  -> Detectar automaticamente o esquema de versão (semver, data, etc.)
#   2:4  -> Procurar updates "modo extremo": GitHub/GitLab/API, HTTP, mirrors, etc.
#   3:3  -> Atualizar pacote + TODA cadeia de dependências (deep update).
#   4:5  -> Patches/hooks em modo supremo: tentar reaproveitar/aplicar/indicar problemas.
#   5:3  -> Metafile "revolucionário": atualiza versão, sources, sha256; deps são mantidas
#           mas há estrutura para re-scan mais tarde (sem silencioso).
#   6:1  -> NÃO construir nem instalar; apenas baixar nova versão e gerar metafile de update.
#
# O que este script faz na prática:
#   - Lê metafile atual (10-repo-metafile.sh).
#   - Detecta tipo de upstream a partir de "sources" / "homepage":
#       * GitHub (API releases/tags)
#       * GitLab (API tags)
#       * Genérico HTTP/FTP (melhor esforço, se configurado)
#       * Git (.git) via "git ls-remote --tags"
#   - Descobre última versão estável (filtra rc/beta/alpha/etc) usando comparação de versão
#     com detecção automática de esquema (semver, data, etc.).
#   - Compara com versão atual:
#       * se já é a mais recente -> loga e não gera nada.
#       * se há nova versão -> baixa tarball(s), calcula sha256, gera novo metafile de update em:
#             /usr/src/adm/update/<categoria>/<nome>/metafile
#         + cria "hook" genérico + diretório "patch".
#   - Para deep update (pacote + deps), usa 32-resolver-deps.sh, se disponível.
#
# NÃO compila nem instala nada. Apenas gerencia UPDATE METADATA.
#
# CLI:
#   40-update-manager.sh check         <categoria> <nome>
#   40-update-manager.sh check-token   <token>            # token: cat/pkg ou pkg
#   40-update-manager.sh update-meta   <categoria> <nome> [--deep]
#   40-update-manager.sh update-meta-token <token> [--deep]
#   40-update-manager.sh world-check
#   40-update-manager.sh help
#
# Ambiente:
#   ADM_ROOT          (default: /usr/src/adm)
#   ADM_REPO          (default: /usr/src/adm/repo)
#   ADM_UPDATE_ROOT   (default: /usr/src/adm/update)
#   ADM_DL_DIR        (default: /usr/src/adm/distfiles)
#   ADM_UPDATE_HTTP_ENABLE_INDEX_SCRAPE=1 para tentar parsing de index HTML simples.
#
# Requisitos externos (para recursos avançados):
#   - curl       (obrigatório para buscar upstream)
#   - sha256sum  (obrigatório para recalcular sha256)
#   - git        (para upstream git:// ou *.git)
#   - jq         (fortemente recomendado para APIs JSON GitHub/GitLab)
#
# Não há erros silenciosos: qualquer falha crítica gera adm_die com mensagem clara.

# ----------------------------------------------------------------------
# Requisitos base
# ----------------------------------------------------------------------

if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 40-update-manager.sh requer bash." >&2
    exit 1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERRO: 40-update-manager.sh requer bash >= 4." >&2
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
ADM_DL_DIR="${ADM_DL_DIR:-$ADM_ROOT/distfiles}"

# Logging: usa 01-log-ui.sh se disponível; senão, fallback.
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

# ----------------------------------------------------------------------
# Dependências de outros scripts
# ----------------------------------------------------------------------

# Metafile API é obrigatória.
if ! declare -F adm_meta_load >/dev/null 2>&1 || \
   ! declare -F adm_meta_get_var >/dev/null 2>&1; then
    adm_die "Funções de metafile (adm_meta_load/adm_meta_get_var) não disponíveis. Carregue 10-repo-metafile.sh."
fi

# Resolver de deps para deep update (opcional, mas muito desejado).
ADM_UPDATE_HAS_DEPS=0
if declare -F adm_deps_resolve_for_pkg >/dev/null 2>&1 && \
   declare -F adm_deps_parse_token >/dev/null 2>&1; then
    ADM_UPDATE_HAS_DEPS=1
fi

# Source manager (para futuros modos que queiram testar download) – opcional aqui.
if declare -F adm_src_fetch_for_pkg >/dev/null 2>&1; then
    : # ok
fi

# ----------------------------------------------------------------------
# Tools externos
# ----------------------------------------------------------------------

adm_update_require_tool() {
    local bin="${1:-}" desc="${2:-}"
    if ! command -v "$bin" >/dev/null 2>&1; then
        adm_die "Ferramenta obrigatória '$bin' não encontrada ($desc)."
    fi
}

adm_update_require_core_tools() {
    adm_update_require_tool curl "necessário para buscar versões upstream"
    adm_update_require_tool sha256sum "necessário para calcular sha256 dos sources"
}

# jq é opcional; se não houver, tentamos parsing mais simples
ADM_UPDATE_HAS_JQ=0
if command -v jq >/dev/null 2>&1; then
    ADM_UPDATE_HAS_JQ=1
fi

# git é opcional; só para upstream via git
ADM_UPDATE_HAS_GIT=0
if command -v git >/dev/null 2>&1; then
    ADM_UPDATE_HAS_GIT=1
fi

# ----------------------------------------------------------------------
# Helpers gerais
# ----------------------------------------------------------------------

adm_update_key_pkg() {
    local c="${1:-}" n="${2:-}"
    printf '%s/%s' "$c" "$n"
}

adm_update_trim() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

adm_update_split_csv() {
    local csv="${1:-}"
    local IFS=','
    local token
    for token in $csv; do
        token="$(adm_update_trim "$token")"
        [ -z "$token" ] && continue
        printf '%s\n' "$token"
    done
}

adm_update_url_basename() {
    local url="${1:-}"
    printf '%s\n' "${url##*/}"
}

# ----------------------------------------------------------------------
# Versão: detecção de esquema e comparação
# ----------------------------------------------------------------------

adm_update_version_detect_scheme() {
    # Heurística:
    #   semver:   1.2.3, 2.0, 10.3.7-rc1 etc
    #   datelike: 20240101, 2024.01.01
    #   other:    fallback
    local v="${1:-}"

    if [[ "$v" =~ ^[0-9]{8}$ ]] || [[ "$v" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]]; then
        printf '%s\n' "date"
    elif [[ "$v" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z.+_]+)?$ ]]; then
        printf '%s\n' "semver"
    else
        printf '%s\n' "other"
    fi
}

adm_update_version_compare() {
    # Compara v1 e v2.
    # Retorna em stdout: -1 (v1 < v2) | 0 (igual) | 1 (v1 > v2)
    local v1="${1:-}" v2="${2:-}"

    if [ "$v1" = "$v2" ]; then
        printf '0\n'
        return 0
    fi

    # Para todos os esquemas, usamos sort -V como comparador "inteligente" numérico.
    local first
    first="$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)"
    if [ "$first" = "$v1" ]; then
        # v1 <= v2
        printf '%s\n' "-1"
    else
        printf '%s\n' "1"
    fi
}

adm_update_version_is_newer() {
    # Retorna 0 se v_new > v_old, senão 1
    local v_old="${1:-}" v_new="${2:-}"
    local cmp
    cmp="$(adm_update_version_compare "$v_old" "$v_new")"
    if [ "$cmp" = "-1" ]; then
        return 0
    else
        return 1
    fi
}

adm_update_is_prerelease() {
    # Detecta se versão parece rc/beta/alpha/pre (considera como não estável).
    local v="${1:-}"
    # heurística: rc, beta, alpha, pre, dev
    if echo "$v" | grep -Eiq '(rc|beta|alpha|pre|dev)'; then
        return 0
    fi
    return 1
}

# ----------------------------------------------------------------------
# Carregar meta do pacote
# ----------------------------------------------------------------------

adm_update_meta_load_pkg() {
    local category="${1:-}" name="${2:-}"

    [ -z "$category" ] && adm_die "adm_update_meta_load_pkg requer categoria"
    [ -z "$name" ]     && adm_die "adm_update_meta_load_pkg requer nome"

    category="$(adm_repo_sanitize_category "$category")"
    name="$(adm_repo_sanitize_name "$name")"

    local metafile="$ADM_REPO/$category/$name/metafile"
    if [ ! -f "$metafile" ]; then
        adm_die "Metafile não encontrado: $metafile"
    fi

    adm_meta_load "$category" "$name"

    local version sources sha256sums homepage description maint run_deps build_deps opt_deps
    version="$(adm_meta_get_var "version")"
    sources="$(adm_meta_get_var "sources")"
    sha256sums="$(adm_meta_get_var "sha256sums")"
    homepage="$(adm_meta_get_var "homepage")"
    description="$(adm_meta_get_var "description")"
    maint="$(adm_meta_get_var "maintainer")"
    run_deps="$(adm_meta_get_var "run_deps")"
    build_deps="$(adm_meta_get_var "build_deps")"
    opt_deps="$(adm_meta_get_var "opt_deps")"

    if [ -z "$version" ]; then
        adm_die "Metafile de $category/$name sem 'version'."
    fi
    if [ -z "$sources" ]; then
        adm_warn "Metafile de $category/$name sem 'sources' – update upstream pode ser limitado."
    fi

    # Exporta para ambiente do chamador (via printf key=value)
    cat <<EOF
version=$version
sources=$sources
sha256sums=$sha256sums
homepage=$homepage
description=$description
maintainer=$maint
run_deps=$run_deps
build_deps=$build_deps
opt_deps=$opt_deps
EOF
}

# ----------------------------------------------------------------------
# Detectar tipo de upstream
# ----------------------------------------------------------------------
# UPSTREAM_TYPE:
#   github, gitlab, git, http, unknown
#
# Estrutura retornada (em formato key=value):
#   type=github
#   base_url=https://github.com/owner/repo
#   repo_owner=owner
#   repo_name=repo
#   tag_template=vVERSION
#   tar_template=https://...VERSION....tar.gz
# etc.
# ----------------------------------------------------------------------

adm_update_guess_upstream_from_url() {
    local url="${1:-}"
    [ -z "$url" ] && return 1

    if echo "$url" | grep -q 'github.com'; then
        # Exemplos:
        #   https://github.com/owner/repo/archive/refs/tags/v1.2.3.tar.gz
        #   https://github.com/owner/repo/archive/v1.2.3.tar.gz
        #   https://github.com/owner/repo/releases/download/v1.2.3/repo-1.2.3.tar.gz
        local proto host path
        proto="${url%%://*}://"
        host="${url#*://}"
        host="${host%%/*}"
        path="${url#*://*/}"  # após first /

        # Extrair owner/repo
        local owner repo rest
        owner="${path%%/*}"
        rest="${path#*/}"
        repo="${rest%%/*}"
        rest="${rest#*/}"

        # Base: https://github.com/owner/repo
        local base="https://$host/$owner/$repo"

        # Tentar extrair padrão de tag a partir do nome do arquivo
        local fname
        fname="$(adm_update_url_basename "$url")"
        # Heurística: procurar versão dentro do fname
        # Exemplo: repo-1.2.3.tar.gz -> prefix="repo-", suffix=".tar.gz"
        # Exemplo: v1.2.3.tar.gz -> prefix="v", suffix=".tar.gz"
        local version_guess=""
        if [[ "$fname" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
            version_guess="${BASH_REMATCH[1]}"
        fi

        local tag_template="VERSION"
        if [[ "$fname" =~ v[0-9]+\.[0-9]+(\.[0-9]+)? ]]; then
            tag_template="vVERSION"
        fi

        # Template de tarball GitHub comum:
        #   $base/archive/refs/tags/<tag>.tar.gz
        local tar_template="$base/archive/refs/tags/$tag_template.tar.gz"

        cat <<EOF
type=github
base_url=$base
repo_owner=$owner
repo_name=$repo
tag_template=$tag_template
tar_template=$tar_template
EOF
        return 0
    fi

    if echo "$url" | grep -q 'gitlab.com'; then
        # simplificado: assumimos https://gitlab.com/owner/repo/-/archive/v1.2.3/repo-v1.2.3.tar.gz
        local proto host path
        proto="${url%%://*}://"
        host="${url#*://}"
        host="${host%%/*}"
        path="${url#*://*/}"

        local owner repo rest
        owner="${path%%/*}"
        rest="${path#*/}"
        repo="${rest%%/*}"

        local base="https://$host/$owner/$repo"

        local fname
        fname="$(adm_update_url_basename "$url")"
        local tag_template="VERSION"
        if [[ "$fname" =~ v[0-9]+\.[0-9]+(\.[0-9]+)? ]]; then
            tag_template="vVERSION"
        fi

        local tar_template="$base/-/archive/$tag_template/${repo}-$tag_template.tar.gz"

        cat <<EOF
type=gitlab
base_url=$base
repo_owner=$owner
repo_name=$repo
tag_template=$tag_template
tar_template=$tar_template
EOF
        return 0
    fi

    if echo "$url" | grep -E -q '\.git($|[?#])' || [[ "$url" =~ ^git:// ]]; then
        cat <<EOF
type=git
git_url=$url
EOF
        return 0
    fi

    if echo "$url" | grep -E -q '^(https?|ftp)://'; then
        cat <<EOF
type=http
base_url=$url
EOF
        return 0
    fi

    cat <<EOF
type=unknown
base_url=$url
EOF
    return 0
}

adm_update_guess_upstream() {
    local sources="${1:-}" homepage="${2:-}"

    # Tenta a partir do primeiro source HTTP/FTP/git
    local first_url=""
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        if echo "$line" | grep -E -q '^(https?|ftp|git)://'; then
            first_url="$line"
            break
        fi
    done < <(adm_update_split_csv "$sources")

    if [ -z "$first_url" ] && [ -n "$homepage" ]; then
        first_url="$homepage"
    fi

    if [ -z "$first_url" ]; then
        adm_warn "Não foi possível encontrar uma URL adequada em sources/homepage para inferir upstream."
        printf 'type=unknown\n'
        return 0
    fi

    adm_update_guess_upstream_from_url "$first_url"
}

# ----------------------------------------------------------------------
# GitHub: obter última tag estável
# ----------------------------------------------------------------------

adm_update_github_latest_tag() {
    local owner="${1:-}" repo="${2:-}"

    [ -z "$owner" ] && adm_die "adm_update_github_latest_tag requer owner"
    [ -z "$repo" ]  && adm_die "adm_update_github_latest_tag requer repo"

    adm_update_require_tool curl "GitHub API"

    local api="https://api.github.com/repos/$owner/$repo/tags"

    local json
    if ! json="$(curl -fsSL "$api")"; then
        adm_warn "Falha ao consultar GitHub API em $api"
        return 1
    fi

    local tags=()
    if [ "$ADM_UPDATE_HAS_JQ" -eq 1 ]; then
        mapfile -t tags < <(printf '%s\n' "$json" | jq -r '.[].name' 2>/dev/null || true)
    else
        # fallback tosco: pegar "name": "v1.2.3"
        mapfile -t tags < <(printf '%s\n' "$json" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi

    if [ "${#tags[@]}" -eq 0 ]; then
        adm_warn "Nenhuma tag encontrada em $api"
        return 1
    fi

    # Filtrar pré-releases
    local stable_tags=() t
    for t in "${tags[@]}"; do
        if adm_update_is_prerelease "$t"; then
            continue
        fi
        stable_tags+=("$t")
    done

    if [ "${#stable_tags[@]}" -eq 0 ]; then
        adm_warn "Todas as tags parecem pré-release para $owner/$repo; usando lista completa."
        stable_tags=("${tags[@]}")
    fi

    # Encontrar maior tag via sort -V
    local max
    max="$(printf '%s\n' "${stable_tags[@]}" | sort -V | tail -n1)"

    printf '%s\n' "$max"
}

# ----------------------------------------------------------------------
# GitLab: obter última tag estável
# ----------------------------------------------------------------------

adm_update_gitlab_latest_tag() {
    local base="${1:-}" # ex: https://gitlab.com/owner/repo

    [ -z "$base" ] && adm_die "adm_update_gitlab_latest_tag requer base"

    adm_update_require_tool curl "GitLab API"

    # API requer "ID de projeto" URL-encoded; simplificamos substituindo "/" por "%2F"
    local path="${base#*://*/}"   # owner/repo
    local encoded
    encoded="$(printf '%s' "$path" | sed 's/\//%2F/g')"

    local api="https://gitlab.com/api/v4/projects/$encoded/repository/tags"

    local json
    if ! json="$(curl -fsSL "$api")"; then
        adm_warn "Falha ao consultar GitLab API em $api"
        return 1
    fi

    local tags=()
    if [ "$ADM_UPDATE_HAS_JQ" -eq 1 ]; then
        mapfile -t tags < <(printf '%s\n' "$json" | jq -r '.[].name' 2>/dev/null || true)
    else
        mapfile -t tags < <(printf '%s\n' "$json" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi

    if [ "${#tags[@]}" -eq 0 ]; then
        adm_warn "Nenhuma tag encontrada em $api"
        return 1
    fi

    local stable_tags=() t
    for t in "${tags[@]}"; do
        if adm_update_is_prerelease "$t"; then
            continue
        fi
        stable_tags+=("$t")
    done

    if [ "${#stable_tags[@]}" -eq 0 ]; then
        adm_warn "Todas as tags parecem pré-release (GitLab); usando lista completa."
        stable_tags=("${tags[@]}")
    fi

    local max
    max="$(printf '%s\n' "${stable_tags[@]}" | sort -V | tail -n1)"

    printf '%s\n' "$max"
}

# ----------------------------------------------------------------------
# Git genérico: git ls-remote --tags
# ----------------------------------------------------------------------

adm_update_git_latest_tag() {
    local git_url="${1:-}"
    [ -z "$git_url" ] && adm_die "adm_update_git_latest_tag requer git_url"

    if [ "$ADM_UPDATE_HAS_GIT" -ne 1 ]; then
        adm_warn "git não disponível; não é possível inspecionar tags de $git_url"
        return 1
    fi

    local lines
    if ! lines="$(git ls-remote --tags "$git_url" 2>/dev/null)"; then
        adm_warn "Falha ao executar 'git ls-remote --tags' em $git_url"
        return 1
    fi

    local tags=() ref
    while IFS= read -r ref || [ -n "$ref" ]; do
        [ -z "$ref" ] && continue
        # ref: SHA refs/tags/v1.2.3 ou refs/tags/v1.2.3^{}
        local name="${ref#*refs/tags/}"
        name="${name%%^*}"
        if [ -z "$name" ]; then
            continue
        fi
        tags+=("$name")
    done <<< "$lines"

    if [ "${#tags[@]}" -eq 0 ]; then
        adm_warn "Nenhuma tag encontrada em git repo: $git_url"
        return 1
    fi

    local stable_tags=() t
    for t in "${tags[@]}"; do
        if adm_update_is_prerelease "$t"; then
            continue
        fi
        stable_tags+=("$t")
    done

    if [ "${#stable_tags[@]}" -eq 0 ]; then
        adm_warn "Todas as tags parecem pré-release (git); usando lista completa."
        stable_tags=("${tags[@]}")
    fi

    local max
    max="$(printf '%s\n' "${stable_tags[@]}" | sort -V | tail -n1)"

    printf '%s\n' "$max"
}

# ----------------------------------------------------------------------
# HTTP genérico: melhor esforço (opcional)
# ----------------------------------------------------------------------

adm_update_http_latest_guess() {
    local url="${1:-}"

    [ "${ADM_UPDATE_HTTP_ENABLE_INDEX_SCRAPE:-0}" -ne 1 ] && return 1

    adm_update_require_tool curl "HTTP index scrape"

    # Tenta baixar o HTML e extrair nomes com padrão numérico.
    local html
    if ! html="$(curl -fsSL "$url")"; then
        adm_warn "Falha ao baixar $url para inspecionar versões."
        return 1
    fi

    # Heurística: pegar coisas tipo foo-1.2.3.tar.gz
    local candidates=()
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        # extrair possíveis nomes contendo versões
        # isso é muito heurístico; usamos grep/awk simples
        if echo "$line" | grep -E -q '[0-9]+\.[0-9]+(\.[0-9]+)?'; then
            # extrair palavras
            for token in $line; do
                if echo "$token" | grep -E -q '[0-9]+\.[0-9]+(\.[0-9]+)?'; then
                    candidates+=("$token")
                fi
            done
        fi
    done <<< "$html"

    if [ "${#candidates[@]}" -eq 0 ]; then
        adm_warn "Nenhum candidato a versão encontrado em $url."
        return 1
    fi

    # extrair versões em si
    local versions=() t
    for t in "${candidates[@]}"; do
        if [[ "$t" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
            versions+=("${BASH_REMATCH[1]}")
        fi
    done

    if [ "${#versions[@]}" -eq 0 ]; then
        adm_warn "Não foi possível extrair versões válidas de $url."
        return 1
    fi

    local uniq
    uniq="$(printf '%s\n' "${versions[@]}" | awk 'NF && !seen[$0]++')"

    local max
    max="$(printf '%s\n' "$uniq" | sort -V | tail -n1)"

    printf '%s\n' "$max"
}

# ----------------------------------------------------------------------
# Determinar latest_version a partir do upstream info
# ----------------------------------------------------------------------

adm_update_find_latest_version() {
    local current_ver="${1:-}" upstream_info="${2:-}"

    [ -z "$current_ver" ] && adm_die "adm_update_find_latest_version requer current_ver"

    local type base repo_owner repo_name git_url
    type="$(printf '%s\n' "$upstream_info" | sed -n 's/^type=\(.*\)$/\1/p')"
    base="$(printf '%s\n' "$upstream_info" | sed -n 's/^base_url=\(.*\)$/\1/p')"
    repo_owner="$(printf '%s\n' "$upstream_info" | sed -n 's/^repo_owner=\(.*\)$/\1/p')"
    repo_name="$(printf '%s\n' "$upstream_info" | sed -n 's/^repo_name=\(.*\)$/\1/p')"
    git_url="$(printf '%s\n' "$upstream_info" | sed -n 's/^git_url=\(.*\)$/\1/p')"

    local latest=""
    case "$type" in
        github)
            latest="$(adm_update_github_latest_tag "$repo_owner" "$repo_name" || true)"
            ;;
        gitlab)
            latest="$(adm_update_gitlab_latest_tag "$base" || true)"
            ;;
        git)
            latest="$(adm_update_git_latest_tag "$git_url" || true)"
            ;;
        http)
            latest="$(adm_update_http_latest_guess "$base" || true)"
            ;;
        *)
            adm_warn "Tipo de upstream desconhecido ou não suportado: $type; não é possível determinar latest_version."
            ;;
    esac

    if [ -z "$latest" ]; then
        return 1
    fi

    printf '%s\n' "$latest"
}

# ----------------------------------------------------------------------
# Construir templates de sources para nova versão
# ----------------------------------------------------------------------

adm_update_build_new_sources_from_template() {
    local old_version="${1:-}" new_version="${2:-}" sources="${3:-}"

    # Estratégia: para cada URL, se contiver old_version (ou tag padrão),
    # substituir old_version por new_version. Caso contrário, reaproveitar.

    local out_sources=()
    local s
    while IFS= read -r s || [ -n "$s" ]; do
        [ -z "$s" ] && continue
        local ns="$s"
        if printf '%s' "$s" | grep -q "$old_version"; then
            ns="${s//$old_version/$new_version}"
        fi
        out_sources+=("$ns")
    done < <(adm_update_split_csv "$sources")

    if [ "${#out_sources[@]}" -eq 0 ]; then
        adm_warn "Nenhuma source encontrada ao tentar construir nova lista; mantendo sources originais."
        printf '%s\n' "$sources"
        return 0
    fi

    local joined=""
    local i
    for i in "${!out_sources[@]}"; do
        if [ "$i" -gt 0 ]; then
            joined+=","
        fi
        joined+="${out_sources[$i]}"
    done
    printf '%s\n' "$joined"
}

# ----------------------------------------------------------------------
# Download de sources & cálculo de sha256
# ----------------------------------------------------------------------

adm_update_download_source() {
    local url="${1:-}"

    adm_update_require_tool curl "download de sources"

    adm_ensure_dir "$ADM_DL_DIR"

    local fname
    fname="$(adm_update_url_basename "$url")"
    if [ -z "$fname" ]; then
        adm_die "Não foi possível determinar nome de arquivo para URL: $url"
    fi

    local dest="$ADM_DL_DIR/$fname"

    adm_info "Baixando source: $url -> $dest"

    if ! curl -fSL -o "$dest" "$url"; then
        adm_die "Falha ao baixar $url para $dest"
    fi

    printf '%s\n' "$dest"
}

adm_update_compute_sha256sums() {
    local sources="${1:-}"

    adm_update_require_tool sha256sum "cálculo de sha256"

    local sums=()
    local url
    while IFS= read -r url || [ -n "$url" ]; do
        [ -z "$url" ] && continue
        local file
        file="$(adm_update_download_source "$url")"
        local sum
        sum="$(sha256sum "$file" | awk '{print $1}')"
        sums+=("$sum")
    done < <(adm_update_split_csv "$sources")

    if [ "${#sums[@]}" -eq 0 ]; then
        adm_die "Nenhuma sha256 gerada; verifique sources."
    fi

    local joined=""
    local i
    for i in "${!sums[@]}"; do
        if [ "$i" -gt 0 ]; then
            joined+=","
        fi
        joined+="${sums[$i]}"
    done
    printf '%s\n' "$joined"
}

# ----------------------------------------------------------------------
# Gerar novo metafile em ADM_UPDATE_ROOT
# ----------------------------------------------------------------------

adm_update_target_dir() {
    local category="${1:-}" name="${2:-}"
    category="$(adm_repo_sanitize_category "$category")"
    name="$(adm_repo_sanitize_name "$name")"
    printf '%s/%s/%s' "$ADM_UPDATE_ROOT" "$category" "$name"
}

adm_update_generate_metafile() {
    local category="${1:-}" name="${2:-}" current_meta_env="${3:-}" new_version="${4:-}" new_sources="${5:-}" new_sha256sums="${6:-}"

    [ -z "$category" ] && adm_die "adm_update_generate_metafile requer categoria"
    [ -z "$name" ]     && adm_die "adm_update_generate_metafile requer nome"
    [ -z "$new_version" ] && adm_die "adm_update_generate_metafile requer new_version"
    [ -z "$new_sources" ] && adm_die "adm_update_generate_metafile requer new_sources"
    [ -z "$new_sha256sums" ] && adm_die "adm_update_generate_metafile requer new_sha256sums"

    local target_dir metafile hookfile patchdir
    target_dir="$(adm_update_target_dir "$category" "$name")"
    metafile="$target_dir/metafile"
    hookfile="$target_dir/hook"
    patchdir="$target_dir/patch"

    adm_ensure_dir "$target_dir"
    adm_ensure_dir "$patchdir"

    # Extrair campos originais
    local version_old sources_old sha_old homepage description maint run_deps build_deps opt_deps
    version_old="$(printf '%s\n' "$current_meta_env" | sed -n 's/^version=\(.*\)$/\1/p')"
    sources_old="$(printf '%s\n' "$current_meta_env" | sed -n 's/^sources=\(.*\)$/\1/p')"
    sha_old="$(printf '%s\n' "$current_meta_env" | sed -n 's/^sha256sums=\(.*\)$/\1/p')"
    homepage="$(printf '%s\n' "$current_meta_env" | sed -n 's/^homepage=\(.*\)$/\1/p')"
    description="$(printf '%s\n' "$current_meta_env" | sed -n 's/^description=\(.*\)$/\1/p')"
    maint="$(printf '%s\n' "$current_meta_env" | sed -n 's/^maintainer=\(.*\)$/\1/p')"
    run_deps="$(printf '%s\n' "$current_meta_env" | sed -n 's/^run_deps=\(.*\)$/\1/p')"
    build_deps="$(printf '%s\n' "$current_meta_env" | sed -n 's/^build_deps=\(.*\)$/\1/p')"
    opt_deps="$(printf '%s\n' "$current_meta_env" | sed -n 's/^opt_deps=\(.*\)$/\1/p')"

    # Para modo 5:3 ("revolucionário"), ideal seria re-scan de deps via build.
    # MAS como opção 6:1 exige "não buildar nem instalar", aqui mantemos os deps atuais,
    # e deixamos bem claro em comentário que eles podem estar defasados.
    #
    # NADA silencioso: o usuário verá isso no metafile.

    cat >"$metafile" <<EOF
name=$name
version=$new_version
category=$category
run_deps=$run_deps
build_deps=$build_deps
opt_deps=$opt_deps
num_builds=0
description=${description:-Atualizado automaticamente a partir de $version_old}
homepage=$homepage
maintainer=$maint
sha256sums=$new_sha256sums
sources=$new_sources
EOF

    adm_info "Novo metafile de update criado: $metafile"

    # Criar hook genérico automático (modo supremo) apenas se não existir
    if [ ! -f "$hookfile" ]; then
        cat >"$hookfile" <<'EOF'
#!/usr/bin/env bash
# Hook genérico gerado automaticamente para updates do ADM.
#
# Pontos de extensão possíveis (estágios):
#   pre_fetch, post_fetch
#   pre_patch, post_patch
#   pre_configure, post_configure
#   pre_build, post_build
#   pre_install, post_install
#
# Use funções com nomes:
#   adm_hook_<stage>_<category>_<name>() { ... }
#
# Exemplo:
#   adm_hook_pre_configure_dev_gcc() { ... }

EOF
        chmod +x "$hookfile" || true
        adm_info "Hook genérico criado: $hookfile"
    else
        adm_info "Hook já existia para $category/$name; mantendo: $hookfile"
    fi

    adm_info "Diretório de patches para update: $patchdir"
}

# ----------------------------------------------------------------------
# Metodologia principal para um pacote: check + update-meta
# ----------------------------------------------------------------------

adm_update_check_one() {
    local category="${1:-}" name="${2:-}"

    category="$(adm_repo_sanitize_category "$category")"
    name="$(adm_repo_sanitize_name "$name")"

    adm_stage "CHECK $category/$name"

    local meta_env
    meta_env="$(adm_update_meta_load_pkg "$category" "$name")"

    local current_version sources homepage
    current_version="$(printf '%s\n' "$meta_env" | sed -n 's/^version=\(.*\)$/\1/p')"
    sources="$(printf '%s\n' "$meta_env" | sed -n 's/^sources=\(.*\)$/\1/p')"
    homepage="$(printf '%s\n' "$meta_env" | sed -n 's/^homepage=\(.*\)$/\1/p')"

    adm_info "Pacote: $category/$name"
    adm_info "Versão atual: $current_version"

    local upstream_info
    upstream_info="$(adm_update_guess_upstream "$sources" "$homepage")"
    local type
    type="$(printf '%s\n' "$upstream_info" | sed -n 's/^type=\(.*\)$/\1/p')"

    adm_info "Tipo de upstream detectado: $type"

    local latest
    if ! latest="$(adm_update_find_latest_version "$current_version" "$upstream_info")"; then
        adm_warn "Não foi possível determinar latest_version para $category/$name; verifique manualmente."
        return 1
    fi

    adm_info "Última versão disponível encontrada: $latest"

    if ! adm_update_version_is_newer "$current_version" "$latest"; then
        adm_info "Pacote $category/$name já está na versão mais recente (>= $latest)."
        return 0
    fi

    adm_info "Atualização disponível para $category/$name: $current_version -> $latest"
    return 0
}

adm_update_meta_one() {
    local category="${1:-}" name="${2:-}"

    adm_update_require_core_tools

    category="$(adm_repo_sanitize_category "$category")"
    name="$(adm_repo_sanitize_name "$name")"

    adm_stage "UPDATE-META $category/$name"

    local meta_env
    meta_env="$(adm_update_meta_load_pkg "$category" "$name")"

    local current_version sources homepage
    current_version="$(printf '%s\n' "$meta_env" | sed -n 's/^version=\(.*\)$/\1/p')"
    sources="$(printf '%s\n' "$meta_env" | sed -n 's/^sources=\(.*\)$/\1/p')"
    homepage="$(printf '%s\n' "$meta_env" | sed -n 's/^homepage=\(.*\)$/\1/p')"

    local upstream_info
    upstream_info="$(adm_update_guess_upstream "$sources" "$homepage")"
    local type
    type="$(printf '%s\n' "$upstream_info" | sed -n 's/^type=\(.*\)$/\1/p')"

    adm_info "Tipo de upstream detectado: $type"

    local latest
    if ! latest="$(adm_update_find_latest_version "$current_version" "$upstream_info")"; then
        adm_die "Falha ao determinar latest_version para $category/$name; não foi gerado update."
    fi

    adm_info "Última versão disponível: $latest"

    if ! adm_update_version_is_newer "$current_version" "$latest"; then
        adm_info "Pacote $category/$name já está na versão mais recente (>= $latest). Nada a fazer."
        return 0
    fi

    adm_info "Nova versão será preparada: $current_version -> $latest (metafile de update apenas, sem build)."

    local new_sources
    new_sources="$(adm_update_build_new_sources_from_template "$current_version" "$latest" "$sources")"

    adm_info "Novas sources calculadas: $new_sources"

    local new_sha
    new_sha="$(adm_update_compute_sha256sums "$new_sources")"

    adm_info "Novos sha256sums: $new_sha"

    adm_update_generate_metafile "$category" "$name" "$meta_env" "$latest" "$new_sources" "$new_sha"

    adm_info "Update metadata finalizado para $category/$name."
}

# ----------------------------------------------------------------------
# Deep update (pacote + cadeia de dependências)
# ----------------------------------------------------------------------

adm_update_meta_deep() {
    local category="${1:-}" name="${2:-}"

    category="$(adm_repo_sanitize_category "$category")"
    name="$(adm_repo_sanitize_name "$name")"

    if [ "$ADM_UPDATE_HAS_DEPS" -ne 1 ]; then
        adm_warn "Resolver de deps (32-resolver-deps.sh) não está disponível; executando update apenas para $category/$name."
        adm_update_meta_one "$category" "$name"
        return 0
    fi

    adm_stage "UPDATE-META-DEEP $category/$name (deps+alvo)"

    local pairs=()
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        pairs+=("$line")
    done < <(adm_deps_resolve_for_pkg "$category" "$name" "all")

    local p catg pkg
    for p in "${pairs[@]}"; do
        catg="${p%% *}"
        pkg="${p#* }"
        adm_update_meta_one "$catg" "$pkg"
    done
}

# ----------------------------------------------------------------------
# Token parsing (cat/pkg ou pkg)
# ----------------------------------------------------------------------

adm_update_parse_token() {
    local token_raw="${1:-}"
    local token
    token="$(adm_update_trim "$token_raw")"
    if [ -z "$token" ]; then
        adm_die "adm_update_parse_token chamado com token vazio."
    fi

    if [[ "$token" == */* ]]; then
        local c="${token%%/*}"
        local n="${token#*/}"
        c="$(adm_repo_sanitize_category "$c")"
        n="$(adm_repo_sanitize_name "$n")"
        printf '%s %s\n' "$c" "$n"
        return 0
    fi

    # Sem categoria: vamos procurar no repo.
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
# World-check (varre todo repo e faz check)
# ----------------------------------------------------------------------

adm_update_world_check() {
    adm_stage "WORLD-CHECK (apenas verificação, sem gerar metafiles)"

    if [ ! -d "$ADM_REPO" ]; then
        adm_die "ADM_REPO não existe: $ADM_REPO"
    fi

    local cat_dir pkg_dir cat pkg
    for cat_dir in "$ADM_REPO"/*; do
        [ -d "$cat_dir" ] || continue
        cat="$(basename "$cat_dir")"
        for pkg_dir in "$cat_dir"/*; do
            [ -d "$pkg_dir" ] || continue
            pkg="$(basename "$pkg_dir")"
            if [ ! -f "$pkg_dir/metafile" ]; then
                continue
            fi
            # Não falha se algum pacote der erro, apenas avisa.
            if ! adm_update_check_one "$cat" "$pkg"; then
                adm_warn "Falha ao checar update para $cat/$pkg; continuando com outros."
            fi
        done
    done
}

# ----------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------

adm_update_usage() {
    cat <<EOF
Uso: $(basename "$0") <comando> [args...]

Comandos:
  check <categoria> <nome>
      - Verifica se há nova versão disponível upstream para o pacote.

  check-token <token>
      - token: "cat/pkg" ou apenas "pkg".
      - Ex: $(basename "$0") check-token bash

  update-meta <categoria> <nome> [--deep]
      - Gera metafile de update em \$ADM_UPDATE_ROOT/categoria/nome/metafile
        (sem build nem instalação).
      - Baixa novas tarballs, calcula novos sha256sums, atualiza sources, version.
      - Se --deep: atualiza também todas as dependências (cadeia completa).

  update-meta-token <token> [--deep]
      - token: "cat/pkg" ou apenas "pkg".

  world-check
      - Faz check de updates para todos os pacotes do repo (sem gerar metafiles).

  help
      - Mostra esta ajuda.

Exemplos:
  $(basename "$0") check sys bash
  $(basename "$0") update-meta sys bash
  $(basename "$0") update-meta sys bash --deep
  $(basename "$0") check-token bash
  $(basename "$0") update-meta-token bash --deep
  $(basename "$0") world-check

Variáveis:
  ADM_ROOT=/usr/src/adm
  ADM_REPO=\$ADM_ROOT/repo
  ADM_UPDATE_ROOT=\$ADM_ROOT/update
  ADM_DL_DIR=\$ADM_ROOT/distfiles
  ADM_UPDATE_HTTP_ENABLE_INDEX_SCRAPE=1  # habilita heurística HTTP para não-Git.
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-help}"
    case "$cmd" in
        check)
            if [ "$#" -ne 3 ]; then
                adm_error "Uso: $0 check <categoria> <nome>"
                exit 1
            fi
            adm_update_check_one "$2" "$3"
            ;;
        check-token)
            if [ "$#" -ne 2 ]; then
                adm_error "Uso: $0 check-token <token>"
                exit 1
            fi
            pair="$(adm_update_parse_token "$2")"
            catg="${pair%% *}"
            pkg="${pair#* }"
            adm_update_check_one "$catg" "$pkg"
            ;;
        update-meta)
            if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
                adm_error "Uso: $0 update-meta <categoria> <nome> [--deep]"
                exit 1
            fi
            deep=0
            if [ "${4:-}" = "--deep" ]; then
                deep=1
            fi
            if [ "$deep" -eq 1 ]; then
                adm_update_meta_deep "$2" "$3"
            else
                adm_update_meta_one "$2" "$3"
            fi
            ;;
        update-meta-token)
            if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
                adm_error "Uso: $0 update-meta-token <token> [--deep]"
                exit 1
            fi
            pair="$(adm_update_parse_token "$2")"
            catg="${pair%% *}"
            pkg="${pair#* }"
            deep=0
            if [ "${3:-}" = "--deep" ]; then
                deep=1
            fi
            if [ "$deep" -eq 1 ]; then
                adm_update_meta_deep "$catg" "$pkg"
            else
                adm_update_meta_one "$catg" "$pkg"
            fi
            ;;
        world-check)
            adm_update_world_check
            ;;
        help|-h|--help)
            adm_update_usage
            ;;
        *)
            adm_error "Comando desconhecido: $cmd"
            adm_update_usage
            exit 1
            ;;
    esac
fi
