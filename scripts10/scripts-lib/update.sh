#!/usr/bin/env bash
# lib/adm/update.sh
#
# Subsistema de UPDATE do ADM
#
# Responsabilidades:
#   - Descobrir versões novas “estáveis” em upstream para:
#       * Pacote alvo
#       * Suas dependências (run_deps, build_deps, opt_deps)
#   - Criar metafiles de update em:
#       $ADM_ROOT/updates/<name>/<versão>.meta
#       e um symlink/arquivo "latest.meta" apontando para a última versão
#   - Heurísticas para upstream:
#       * GitHub (homepage ou sources apontando para github.com)
#       * GitLab (básico)
#       * Tarballs em diretórios de download (HTML listing simples)
#       * Fallback: nenhuma atualização encontrada → log claro
#
# Nenhum erro silencioso: qualquer problema relevante é logado.
#
# Formato de metafile (igual ao repo):
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
# Variáveis de controle:
#   ADM_UPDATE_DRYRUN=1     → NÃO escreve/metafiles, só loga o que faria
#   ADM_UPDATE_MAX_DEPTH    → limite recursão em deps (default: 3)
#   ADM_UPDATE_STRICT_STABLE=1 → ignore versões com alpha/beta/rc/pre (default: 1)
#
###############################################################################
# Proteção contra múltiplos loads
###############################################################################
if [ -n "${ADM_UPDATE_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
ADM_UPDATE_LOADED=1
###############################################################################
# Dependências: log + core + repo + deps
###############################################################################
# -------- LOG ---------------------------------------------------------
if ! command -v adm_log_update >/dev/null 2>&1; then
    # Fallback mínimo se log.sh ainda não foi carregado
    adm_log()         { printf '%s\n' "$*" >&2; }
    adm_log_info()    { adm_log "[INFO]    $*"; }
    adm_log_warn()    { adm_log "[WARN]    $*"; }
    adm_log_error()   { adm_log "[ERROR]   $*"; }
    adm_log_debug()   { :; }
    adm_log_update()  { adm_log "[UPDATE]  $*"; }
fi

# -------- CORE (paths, helpers) --------------------------------------
if command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_core_init_paths
fi

if ! command -v adm_mkdir_p >/dev/null 2>&1; then
    adm_mkdir_p() {
        if [ $# -ne 1 ]; then
            adm_log_error "adm_mkdir_p requer 1 argumento: DIR"
            return 1
        fi
        mkdir -p -- "$1" 2>/dev/null || {
            adm_log_error "Falha ao criar diretório: %s" "$1"
            return 1
        }
    }
fi

if ! command -v adm_rm_rf_safe >/dev/null 2>&1; then
    adm_rm_rf_safe() {
        if [ $# -ne 1 ]; then
            adm_log_error "adm_rm_rf_safe requer 1 argumento: CAMINHO"
            return 1
        fi
        rm -rf -- "$1" 2>/dev/null || {
            adm_log_warn "Falha ao remover recursivamente: %s" "$1"
            return 1
        }
    }
fi

# -------- REPO --------------------------------------------------------
if ! command -v adm_repo_load_metafile >/dev/null 2>&1; then
    adm_log_error "repo.sh não carregado; adm_repo_load_metafile ausente. update.sh ficará limitado."
fi

if ! command -v adm_repo_metafile_path >/dev/null 2>&1; then
    adm_repo_metafile_path() {
        # fallback: assume layout padrão $ADM_ROOT/repo/<category>/<name>/metafile
        if [ $# -ne 2 ]; then
            adm_log_error "adm_repo_metafile_path (fallback) requer 2 argumentos: CATEGORIA NOME"
            return 1
        fi
        local c="$1" n="$2"
        printf '%s/repo/%s/%s/metafile\n' "${ADM_ROOT:-/usr/src/adm}" "$c" "$n"
        return 0
    }
fi

if ! command -v adm_repo_parse_deps >/dev/null 2>&1; then
    adm_log_warn "adm_repo_parse_deps ausente; usando parser CSV simples."
    adm_repo_parse_deps() {
        printf '%s\n' "$1" | tr ',' '\n'
    }
fi

# -------- DEPS (para mapear nomes → specs) ---------------------------
if ! command -v adm_deps_find_pkg_for_name >/dev/null 2>&1; then
    # Heurística: procura em $ADM_ROOT/repo/*/<name>/metafile
    adm_deps_find_pkg_for_name() {
        if [ $# -ne 1 ]; then
            adm_log_error "adm_deps_find_pkg_for_name (fallback) requer 1 argumento: NOME"
            return 1
        fi
        local name="$1"
        local base="${ADM_ROOT:-/usr/src/adm}/repo"
        [ -d "$base" ] || return 1
        local mf
        mf="$(find "$base" -maxdepth 3 -type f -name 'metafile' -path "*/$name/metafile" 2>/dev/null | head -n1)" || mf=""
        [ -z "$mf" ] && return 1
        local cat
        cat="$(printf '%s\n' "$mf" | sed "s|$base/||" | cut -d'/' -f1)"
        [ -z "$cat" ] && return 1
        printf '%s/%s\n' "$cat" "$name"
        return 0
    }
fi

# -------- PATHS GLOBAIS ----------------------------------------------
: "${ADM_ROOT:=${ADM_ROOT:-/usr/src/adm}}"
: "${ADM_STATE_DIR:=${ADM_STATE_DIR:-$ADM_ROOT/state}}"
: "${ADM_LOG_DIR:=${ADM_LOG_DIR:-$ADM_ROOT/logs}}"

: "${ADM_UPDATES_DIR:=${ADM_UPDATES_DIR:-$ADM_ROOT/updates}}"

adm_mkdir_p "$ADM_STATE_DIR"   || adm_log_error "Falha ao criar ADM_STATE_DIR: %s" "$ADM_STATE_DIR"
adm_mkdir_p "$ADM_UPDATES_DIR" || adm_log_error "Falha ao criar ADM_UPDATES_DIR: %s" "$ADM_UPDATES_DIR"

###############################################################################
# Configuração
###############################################################################

: "${ADM_UPDATE_DRYRUN:=0}"
: "${ADM_UPDATE_MAX_DEPTH:=3}"
: "${ADM_UPDATE_STRICT_STABLE:=1}"

# HTTP timeout em segundos (para curl/wget)
: "${ADM_UPDATE_HTTP_TIMEOUT:=15}"

# rastreador de pacotes visitados (para evitar loops recursivos)
ADM_UPDATE_VISITED=""

###############################################################################
# Helpers básicos
###############################################################################

adm_update__trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

adm_update__is_visited() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_update__is_visited requer 1 argumento: SPEC"
        return 1
    fi
    local spec="$1"
    case " $ADM_UPDATE_VISITED " in
        *" $spec "*) return 0 ;;
        *) return 1 ;;
    esac
}

adm_update__mark_visited() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_update__mark_visited requer 1 argumento: SPEC"
        return 1
    fi
    local spec="$1"
    if ! adm_update__is_visited "$spec"; then
        ADM_UPDATE_VISITED="$ADM_UPDATE_VISITED $spec"
    fi
}

# Comparação de versões (semântica básica) usando sort -V.
# Retornos:
#   0 → v1 == v2
#   1 → v1  > v2
#  -1 → v1  < v2
adm_update_version_cmp() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_update_version_cmp requer 2 argumentos: V1 V2"
        return 1
    fi
    local v1="$1" v2="$2"

    if [ "$v1" = "$v2" ]; then
        printf '0\n'
        return 0
    fi

    # sort -V coloca menor primeiro; comparando a ordem
    local first
    first="$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)"
    if [ "$first" = "$v1" ]; then
        # v1 < v2
        printf '-1\n'
    else
        printf '1\n'
    fi

    return 0
}

adm_update_is_prerelease() {
    # Considera pre-release se contém alpha|beta|rc|pre ou um sufixo -something
    if [ $# -ne 1 ]; then
        adm_log_error "adm_update_is_prerelease requer 1 argumento: VERSÃO"
        return 1
    fi
    local v="$1"

    case "$v" in
        *alpha*|*beta*|*rc*|*pre*|*dev*|*-*|*_*)
            printf '1\n'
            ;;
        *)
            printf '0\n'
            ;;
    esac
    return 0
}

adm_update_select_latest_stable() {
    # Lê versões de stdin, uma por linha, e imprime a maior estável.
    # Se nenhuma estável, e STRICT_STABLE=0, pega maior de qualquer.
    local best="" best_any=""
    local v pre is_stable

    while IFS= read -r v || [ -n "$v" ]; do
        v="$(adm_update__trim "$v")"
        [ -z "$v" ] && continue

        # any (maior no geral)
        if [ -z "$best_any" ]; then
            best_any="$v"
        else
            if [ "$(adm_update_version_cmp "$v" "$best_any")" = "1" ]; then
                best_any="$v"
            fi
        fi

        pre="$(adm_update_is_prerelease "$v" 2>/dev/null || echo '0')"
        if [ "$pre" = "1" ]; then
            continue
        fi

        if [ -z "$best" ]; then
            best="$v"
        else
            if [ "$(adm_update_version_cmp "$v" "$best")" = "1" ]; then
                best="$v"
            fi
        fi
    done

    if [ -n "$best" ]; then
        printf '%s\n' "$best"
    else
        if [ "$ADM_UPDATE_STRICT_STABLE" -eq 0 ] && [ -n "$best_any" ]; then
            adm_log_warn "Nenhuma versão estável encontrada; usando maior versão incluindo pre-release: %s" "$best_any"
            printf '%s\n' "$best_any"
        else
            printf '\n'
        fi
    fi
}

###############################################################################
# HTTP helper (curl / wget)
###############################################################################

adm_update__http_get() {
    # args: URL
    if [ $# -ne 1 ]; then
        adm_log_error "adm_update__http_get requer 1 argumento: URL"
        return 1
    fi
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time "$ADM_UPDATE_HTTP_TIMEOUT" "$url" 2>/dev/null
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout="$ADM_UPDATE_HTTP_TIMEOUT" "$url" 2>/dev/null
        return $?
    fi

    adm_log_error "Nenhum cliente HTTP disponível (curl/wget) para acessar: %s" "$url"
    return 1
}

###############################################################################
# Detecção de upstream
###############################################################################

# Retornos via variáveis de ambiente:
#   ADM_UPD_UPSTREAM_TYPE: github|gitlab|generic|unknown
#   ADM_UPD_UPSTREAM_ID:   para github/gitlab → owner/repo
#   ADM_UPD_BASE_URL:      URL base de download/listing se aplicável
adm_update_detect_upstream() {
    # Usa ADM_META_homepage e ADM_META_sources
    ADM_UPD_UPSTREAM_TYPE="unknown"
    ADM_UPD_UPSTREAM_ID=""
    ADM_UPD_BASE_URL=""

    local homepage="${ADM_META_homepage:-}"
    local sources="${ADM_META_sources:-}"

    # Prioridade: homepage → sources
    if printf '%s\n' "$homepage" | grep -q 'github.com'; then
        ADM_UPD_UPSTREAM_TYPE="github"
        # extrai owner/repo do homepage (ex: https://github.com/owner/repo)
        ADM_UPD_UPSTREAM_ID="$(printf '%s\n' "$homepage" | sed -n 's|.*github\.com/||p' | cut -d'/' -f1,2 | sed 's/\.git$//')"
        [ -n "$ADM_UPD_UPSTREAM_ID" ] || ADM_UPD_UPSTREAM_TYPE="unknown"
        return 0
    fi

    if printf '%s\n' "$sources" | grep -q 'github.com'; then
        ADM_UPD_UPSTREAM_TYPE="github"
        ADM_UPD_UPSTREAM_ID="$(printf '%s\n' "$sources" | tr ',' '\n' | grep 'github.com' | head -n1 | sed 's|.*github\.com/||' | cut -d'/' -f1,2 | sed 's/\.git$//')"
        [ -n "$ADM_UPD_UPSTREAM_ID" ] || ADM_UPD_UPSTREAM_TYPE="unknown"
        return 0
    fi

    if printf '%s\n' "$homepage" | grep -q 'gitlab.com'; then
        ADM_UPD_UPSTREAM_TYPE="gitlab"
        ADM_UPD_UPSTREAM_ID="$(printf '%s\n' "$homepage" | sed -n 's|.*gitlab\.com/||p' | cut -d'/' -f1,2 | sed 's/\.git$//')"
        [ -n "$ADM_UPD_UPSTREAM_ID" ] || ADM_UPD_UPSTREAM_TYPE="unknown"
        return 0
    fi

    if printf '%s\n' "$sources" | grep -q 'gitlab.com'; then
        ADM_UPD_UPSTREAM_TYPE="gitlab"
        ADM_UPD_UPSTREAM_ID="$(printf '%s\n' "$sources" | tr ',' '\n' | grep 'gitlab.com' | head -n1 | sed 's|.*gitlab\.com/||' | cut -d'/' -f1,2 | sed 's/\.git$//')"
        [ -n "$ADM_UPD_UPSTREAM_ID" ] || ADM_UPD_UPSTREAM_TYPE="unknown"
        return 0
    fi

    # generic: tenta descobrir base de diretório a partir do sources (URL http(s) com tarballs)
    local first_src
    first_src="$(printf '%s\n' "$sources" | tr ',' '\n' | head -n1)"
    if printf '%s\n' "$first_src" | grep -Eq '^https?://'; then
        ADM_UPD_UPSTREAM_TYPE="generic"
        ADM_UPD_BASE_URL="$(printf '%s\n' "$first_src" | sed 's|\(.*\)/.*|\1/|')"
        return 0
    fi

    # fallback
    ADM_UPD_UPSTREAM_TYPE="unknown"
    return 0
}

###############################################################################
# Coleta de versões em GitHub / GitLab / genérico
###############################################################################

adm_update__github_versions() {
    # Usa ADM_UPD_UPSTREAM_ID (owner/repo)
    if [ -z "${ADM_UPD_UPSTREAM_ID:-}" ]; then
        return 1
    fi
    local owner repo
    owner="${ADM_UPD_UPSTREAM_ID%/*}"
    repo="${ADM_UPD_UPSTREAM_ID#*/}"

    # Tenta API de releases, depois tags
    local url out
    url="https://api.github.com/repos/$owner/$repo/releases?per_page=100"
    out="$(adm_update__http_get "$url" 2>/dev/null || true)"

    if [ -n "$out" ]; then
        printf '%s\n' "$out" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
        return 0
    fi

    url="https://api.github.com/repos/$owner/$repo/tags?per_page=100"
    out="$(adm_update__http_get "$url" 2>/dev/null || true)"
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
        return 0
    fi

    return 1
}

adm_update__gitlab_versions() {
    # Usa ADM_UPD_UPSTREAM_ID (group/project) – API simplificada
    if [ -z "${ADM_UPD_UPSTREAM_ID:-}" ]; then
        return 1
    fi
    local proj
    # GitLab precisa de URL-encoding, mas aqui simplificamos
    proj="$(printf '%s\n' "$ADM_UPD_UPSTREAM_ID" | sed 's|/|%2F|g')"

    local url out
    url="https://gitlab.com/api/v4/projects/${proj}/releases"
    out="$(adm_update__http_get "$url" 2>/dev/null || true)"

    if [ -n "$out" ]; then
        printf '%s\n' "$out" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
        return 0
    fi

    url="https://gitlab.com/api/v4/projects/${proj}/repository/tags"
    out="$(adm_update__http_get "$url" 2>/dev/null || true)"
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
        return 0
    fi

    return 1
}

adm_update__generic_dir_versions() {
    # Heurística: baixa HTML do diretório e procura padrões "name-x.y.z.tar"
    # Usa ADM_META_name e ADM_UPD_BASE_URL
    local name="${ADM_META_name:-}"
    local base="${ADM_UPD_BASE_URL:-}"

    [ -n "$name" ] || return 1
    [ -n "$base" ] || return 1

    local html
    html="$(adm_update__http_get "$base" 2>/dev/null || true)"
    [ -z "$html" ] && return 1

    # Procura name-X.Y.Z com algumas variações
    printf '%s\n' "$html" | \
        sed -n "s/.*\(${name}-[0-9][0-9A-Za-z\.\-]*\)\.tar.*/\1/p" | \
        sed "s/^${name}-//" | \
        sort -u
}

adm_update_collect_versions() {
    # Usa ADM_UPD_UPSTREAM_TYPE e *_ID para preencher ADM_UPD_VERSIONS (linha por versão)
    ADM_UPD_VERSIONS=""
    local type="${ADM_UPD_UPSTREAM_TYPE:-unknown}"
    local out=""

    case "$type" in
        github)
            out="$(adm_update__github_versions 2>/dev/null || true)"
            ;;
        gitlab)
            out="$(adm_update__gitlab_versions 2>/dev/null || true)"
            ;;
        generic)
            out="$(adm_update__generic_dir_versions 2>/dev/null || true)"
            ;;
        *)
            out=""
            ;;
    esac

    if [ -z "$out" ]; then
        adm_log_update "Não foi possível obter lista de versões para upstream type=%s id=%s" \
            "$type" "${ADM_UPD_UPSTREAM_ID:-}"
        return 1
    fi

    # Normaliza: remove prefixos "v" ou "release-" etc.
    ADM_UPD_VERSIONS="$(printf '%s\n' "$out" | sed 's/^v//' | sed 's/^release-//' | sed 's/^refs\/tags\///' | sort -u)"
    return 0
}

###############################################################################
# Geração de novas sources (heurística) e metafile
###############################################################################

adm_update__sources_for_new_version() {
    # Tenta ajustar URLs de sources atuais substituindo versão antiga pela nova.
    # Usa ADM_META_sources, ADM_META_version, ADM_UPD_NEW_VERSION.
    ADM_UPD_NEW_SOURCES=""

    local sources="${ADM_META_sources:-}"
    local oldv="${ADM_META_version:-}"
    local newv="${ADM_UPD_NEW_VERSION:-}"

    if [ -z "$sources" ] || [ -z "$oldv" ] || [ -z "$newv" ]; then
        adm_log_update "Não é possível ajustar sources (faltam dados). Mantendo sources originais."
        ADM_UPD_NEW_SOURCES="$sources"
        return 0
    fi

    # Substituição simples: oldv → newv em cada URL
    local s out=""
    while IFS= read -r s || [ -n "$s" ]; do
        s="$(adm_update__trim "$s")"
        [ -z "$s" ] && continue
        out="${out}${s//$oldv/$newv},"
    done <<EOF
$(printf '%s\n' "$sources" | tr ',' '\n')
EOF

    out="${out%,}"
    ADM_UPD_NEW_SOURCES="$out"
    return 0
}

adm_update__write_metafile() {
    # args: CATEGORY NAME
    # Usa ADM_META_* + ADM_UPD_NEW_VERSION + ADM_UPD_NEW_SOURCES para gravar update metafile.
    if [ $# -ne 2 ]; then
        adm_log_error "adm_update__write_metafile requer 2 argumentos: CATEGORIA NOME"
        return 1
    fi
    local category="$1" name="$2"

    local newv="${ADM_UPD_NEW_VERSION:-}"
    if [ -z "$newv" ]; then
        adm_log_error "ADM_UPD_NEW_VERSION não definido ao gravar metafile de update."
        return 1
    fi

    local destdir="$ADM_UPDATES_DIR/$name"
    local metafile="$destdir/$newv.meta"
    local latest="$destdir/latest.meta"

    adm_mkdir_p "$destdir" || return 1

    adm_log_update "Criando metafile de update: %s" "$metafile"

    if [ "$ADM_UPDATE_DRYRUN" -eq 1 ]; then
        adm_log_update "[DRY-RUN] Não será escrito metafile. Conteúdo seria baseado em ADM_META_*."
        return 0
    fi

    # sha256sums: não temos o hash ainda; zera para forçar atualização posterior
    local sha=""

    # run/build/opt_deps mantidos
    cat >"$metafile" <<EOF
name=${ADM_META_name:-$name}
version=${ADM_UPD_NEW_VERSION}
category=${ADM_META_category:-$category}
run_deps=${ADM_META_run_deps:-}
build_deps=${ADM_META_build_deps:-}
opt_deps=${ADM_META_opt_deps:-}
num_builds=0
description=${ADM_META_description:-}
homepage=${ADM_META_homepage:-}
maintainer=${ADM_META_maintainer:-}
sha256sums=${sha}
sources=${ADM_UPD_NEW_SOURCES:-${ADM_META_sources:-}}
EOF

    # Atualiza latest.meta
    if [ -e "$latest" ] || [ -L "$latest" ]; then
        rm -f "$latest" 2>/dev/null || adm_log_warn "Não foi possível remover latest.meta antigo para %s." "$name"
    fi
    # symlink relativo
    (
        cd "$destdir" || exit 1
        ln -s "$(basename "$metafile")" latest.meta 2>/dev/null || cp -f "$(basename "$metafile")" latest.meta
    ) || adm_log_warn "Falha ao criar latest.meta em %s." "$destdir"

    adm_log_update "Metafile de update criado: %s (e latest.meta atualizado)" "$metafile"
    return 0
}

###############################################################################
# Pipeline de update de um pacote
###############################################################################

# ADM_UPD_NEW_VERSION será preenchida se um update for encontrado
ADM_UPD_NEW_VERSION=""
ADM_UPD_VERSIONS=""

adm_update__load_metafile() {
    # args: CATEGORY NAME
    if [ $# -ne 2 ]; then
        adm_log_error "adm_update__load_metafile requer 2 argumentos: CATEGORIA NOME"
        return 1
    fi
    local category="$1" name="$2"

    if ! command -v adm_repo_load_metafile >/dev/null 2>&1; then
        adm_log_error "adm_repo_load_metafile não disponível; não é possível carregar metafile de %s/%s." "$category" "$name"
        return 1
    fi

    if ! adm_repo_load_metafile "$category" "$name" "ADM_META_"; then
        adm_log_error "Falha ao carregar metafile de %s/%s." "$category" "$name"
        return 1
    fi

    # Garante alguns campos chave
    [ -n "${ADM_META_name:-}" ]      || ADM_META_name="$name"
    [ -n "${ADM_META_category:-}" ]  || ADM_META_category="$category"

    return 0
}

adm_update__find_new_version() {
    # Usa ADM_META_version + upstream para definir ADM_UPD_NEW_VERSION
    local current="${ADM_META_version:-}"
    if [ -z "$current" ]; then
        adm_log_warn "Metafile não define 'version'; não será possível comparar upstream."
        ADM_UPD_NEW_VERSION=""
        return 1
    fi

    adm_update_detect_upstream

    if [ "${ADM_UPD_UPSTREAM_TYPE:-unknown}" = "unknown" ]; then
        adm_log_update "Upstream desconhecido para %s/%s (homepage=%s, sources=%s)" \
            "${ADM_META_category:-}" "${ADM_META_name:-}" "${ADM_META_homepage:-}" "${ADM_META_sources:-}"
        ADM_UPD_NEW_VERSION=""
        return 1
    fi

    adm_log_update "Detectado upstream para %s/%s: type=%s id=%s base=%s" \
        "${ADM_META_category:-}" "${ADM_META_name:-}" \
        "$ADM_UPD_UPSTREAM_TYPE" "${ADM_UPD_UPSTREAM_ID:-}" "${ADM_UPD_BASE_URL:-}"

    if ! adm_update_collect_versions; then
        ADM_UPD_NEW_VERSION=""
        return 1
    fi

    local best
    best="$(printf '%s\n' "$ADM_UPD_VERSIONS" | adm_update_select_latest_stable)"
    best="$(adm_update__trim "$best")"

    if [ -z "$best" ]; then
        adm_log_update "Nenhuma versão candidata obtida para %s/%s." \
            "${ADM_META_category:-}" "${ADM_META_name:-}"
        ADM_UPD_NEW_VERSION=""
        return 1
    fi

    # compara com versão atual
    local cmp
    cmp="$(adm_update_version_cmp "$best" "$current" 2>/dev/null || echo 0)"

    if [ "$cmp" = "1" ]; then
        ADM_UPD_NEW_VERSION="$best"
        adm_log_update "Versão nova detectada para %s/%s: atual=%s, novo=%s" \
            "${ADM_META_category:-}" "${ADM_META_name:-}" "$current" "$best"
        return 0
    elif [ "$cmp" = "0" ]; then
        adm_log_update "Versão upstream igual à atual para %s/%s (%s)." \
            "${ADM_META_category:-}" "${ADM_META_name:-}" "$current"
        ADM_UPD_NEW_VERSION=""
        return 1
    else
        adm_log_update "Versão upstream (%s) é menor que atual (%s) para %s/%s; nada a fazer." \
            "$best" "$current" "${ADM_META_category:-}" "${ADM_META_name:-}"
        ADM_UPD_NEW_VERSION=""
        return 1
    fi
}

adm_update_package() {
    # args: CATEGORY NAME [DEPTH]
    if [ $# -lt 2 ] || [ $# -gt 3 ]; then
        adm_log_error "adm_update_package requer 2 ou 3 argumentos: CATEGORIA NOME [DEPTH]"
        return 1
    fi
    local category="$1" name="$2"
    local depth="${3:-0}"

    local spec="$category/$name"

    if [ "$depth" -gt "$ADM_UPDATE_MAX_DEPTH" ]; then
        adm_log_update "Profundidade máxima de update atingida (%s) em %s; interrompendo recursão." "$ADM_UPDATE_MAX_DEPTH" "$spec"
        return 0
    fi

    if adm_update__is_visited "$spec"; then
        adm_log_update "Pacote %s já processado em update (evitando loop)." "$spec"
        return 0
    fi
    adm_update__mark_visited "$spec"

    adm_log_update "=== UPDATE: analisando pacote %s (depth=%s) ===" "$spec" "$depth"

    if ! adm_update__load_metafile "$category" "$name"; then
        adm_log_error "Não foi possível carregar metafile para %s." "$spec"
        return 1
    fi

    # tenta achar nova versão
    if ! adm_update__find_new_version; then
        adm_log_update "Nenhuma atualização encontrada para %s." "$spec"
    else
        # calcula novas sources
        adm_update__sources_for_new_version

        # grava metafile de update
        adm_update__write_metafile "$category" "$name" || adm_log_error "Falha ao criar metafile de update para %s." "$spec"
    fi

    # Atualiza deps também (recursivamente)
    local deps_csv dep
    for field in run_deps build_deps opt_deps; do
        deps_csv="$(eval "printf '%s' \"\${ADM_META_${field}:-}\"")"
        [ -z "$deps_csv" ] && continue
        while IFS= read -r dep || [ -n "$dep" ]; do
            dep="$(adm_update__trim "$dep")"
            [ -z "$dep" ] && continue

            # Resolve categoria/nome do dep
            local dep_spec dep_cat dep_name
            if printf '%s\n' "$dep" | grep -q '/'; then
                dep_spec="$dep"
            else
                dep_spec="$(adm_deps_find_pkg_for_name "$dep" 2>/dev/null || true)"
            fi

            if [ -z "$dep_spec" ]; then
                adm_log_update "Não foi possível mapear dependência '%s' para pacote (campo=%s de %s)." "$dep" "$field" "$spec"
                continue
            fi

            dep_cat="${dep_spec%%/*}"
            dep_name="${dep_spec##*/}"

            adm_update_package "$dep_cat" "$dep_name" "$((depth+1))"
        done <<EOF
$(adm_repo_parse_deps "$deps_csv")
EOF
    done

    adm_log_update "=== UPDATE: pacote %s analisado ===" "$spec"
    return 0
}

###############################################################################
# Frontends de alto nível
###############################################################################

# Atualiza um pacote + deps (entrypoint principal)
adm_update_pkg_with_deps() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_update_pkg_with_deps requer 2 argumentos: CATEGORIA NOME"
        return 1
    fi
    local category="$1" name="$2"

    ADM_UPDATE_VISITED=""
    adm_update_package "$category" "$name" 0
}

# Verifica todos os pacotes do repo para possíveis updates (superficial).
# NÃO resolve deps recursivamente aqui; apenas chama update básico.
adm_update_all_repo() {
    local base="$ADM_ROOT/repo"
    if [ ! -d "$base" ]; then
        adm_log_error "Diretório de repo não existe: %s" "$base"
        return 1
    fi

    ADM_UPDATE_VISITED=""

    adm_log_update "Varredura de update para todos os pacotes em %s" "$base"

    local mf category name spec
    while IFS= read -r mf || [ -n "$mf" ]; do
        [ -f "$mf" ] || continue
        # caminho ex: /usr/src/adm/repo/<cat>/<name>/metafile
        category="$(printf '%s\n' "$mf" | sed "s|$base/||" | cut -d'/' -f1)"
        name="$(printf '%s\n' "$mf" | sed "s|$base/||" | cut -d'/' -f2)"
        spec="$category/$name"
        adm_update_package "$category" "$name" 0 || adm_log_warn "Falha parcial ao tentar update de %s (continuando)." "$spec"
    done <<EOF
$(find "$base" -mindepth 3 -maxdepth 3 -type f -name 'metafile' 2>/dev/null)
EOF

    adm_log_update "Varredura de update concluída."
    return 0
}

###############################################################################
# Inicialização
###############################################################################

adm_update_init() {
    adm_log_debug "Subsistema de update (update.sh) carregado. dryrun=%s strict_stable=%s max_depth=%s" \
        "$ADM_UPDATE_DRYRUN" "$ADM_UPDATE_STRICT_STABLE" "$ADM_UPDATE_MAX_DEPTH"
}

adm_update_init
