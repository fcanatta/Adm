#!/usr/bin/env bash
# 10.10-update-upstream-tracker.sh
# Descobre versões upstream, compara e gera metafile de update opcionalmente
# baixando fontes e calculando sha256sums.
###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__ut_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] update-upstream-tracker falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __ut_err_trap ERR

###############################################################################
# Caminhos, logging, utilitários
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_ROOT}/db}"
ADM_META_DIR="${ADM_META_DIR:-${ADM_ROOT}/metafiles}"
UPDATE_DIR="${UPDATE_DIR:-${ADM_ROOT}/update}"

__ensure_dir(){
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  if [[ ! -d "$d" ]]; then
    if command -v install >/dev/null 2>&1; then
      if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
        sudo install -d -m "$mode" -o "$owner" -g "$group" "$d"
      else
        install -d -m "$mode" -o "$owner" -g "$group" "$d"
      fi
    else
      mkdir -p "$d"; chmod "$mode" "$d"; chown "$owner:$group" "$d" || true
    fi
  fi
}
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_LOG_DIR"; __ensure_dir "$ADM_TMPDIR"; __ensure_dir "$ADM_DB_DIR"; __ensure_dir "$UPDATE_DIR"

# Cores
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
ut_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
ut_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
ut_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
ut_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
tmpfile(){ mktemp "${ADM_TMPDIR}/ut.XXXXXX"; }
trim(){ sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
sha256f(){ sha256sum "$1" | awk '{print $1}'; }
adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }

# Locks
__lock(){
  local name="$1"; __ensure_dir "$ADM_STATE_DIR/locks"
  exec {__UT_FD}>"$ADM_STATE_DIR/locks/${name}.lock"
  flock -n ${__UT_FD} || { ut_warn "aguardando lock de ${name}…"; flock ${__UT_FD}; }
}
__unlock(){ :; }

###############################################################################
# Hooks
###############################################################################
declare -A ADM_META  # category, name, version, homepage
__pkg_root(){
  local c="${ADM_META[category]:-}" n="${ADM_META[name]:-}"
  [[ -n "$c" && -n "$n" ]] || { echo ""; return 1; }
  printf '%s/%s/%s' "$ADM_ROOT" "$c" "$n"
}
__hooks_dirs(){
  local pr; pr="$(__pkg_root)" || true
  printf '%s\n' "$pr/hooks" "$ADM_ROOT/hooks"
}
ut_hooks_run(){
  local stage="${1:?}"; shift || true
  local d f ran=0
  for d in $(__hooks_dirs); do
    [[ -d "$d" ]] || continue
    for f in "$d/$stage" "$d/$stage.sh"; do
      if [[ -x "$f" ]]; then
        ut_info "Hook: $(realpath -m "$f")"
        ( set -Eeuo pipefail; "$f" "$@" )
        ran=1
      fi
    done
  done
  (( ran )) || ut_info "Hook '${stage}': nenhum"
}

###############################################################################
# CLI
###############################################################################
JSON_OUT=0
LOGPATH=""
DRYRUN=0

# pacote/metafile
ADM_META[category]=""  # --category
ADM_META[name]=""      # --name
ADM_META[version]=""   # detectado do metafile (ou override --current-version)
CURRENT_VERSION_OVERRIDE=""

META_PATH=""            # caminho alternativo do metafile
OUT_DIR=""              # diretório base para salvar update (default: ${UPDATE_DIR}/cat/name)
AUTO_APPLY=0           # escreve metafile de update
DOWNLOAD=0             # baixa fontes novas e calcula sha256s
PARALLEL="${JOBS:-$(command -v nproc >/dev/null 2>&1 && nproc || echo 4)}"
INCLUDE_PRERELEASE=0   # incluir RC/beta/alpha
VER_REGEX="^[0-9]+([.][0-9]+)*([.-]p[0-9]+)?$"  # regex de versões estáveis padrão
TAG_PREFIX=""          # prefixo para strip (ex: 'v')

# providers e estratégia
PREFERRED_PROVIDER="auto"    # auto|github|gitlab|sourceforge|git|http|rsync
GITHUB_TOKEN="${GITHUB_TOKEN:-}"  # se existir, usa API
GIT_STRATEGY="tags"          # tags|releases
HTTP_LISTING_DEPTH=1
RSYNC_MODULE=""
VERIFY_SIG=0                 # tenta baixar .asc/.sig e verificar com gpg

ut_usage(){
  cat <<'EOF'
Uso:
  10.10-update-upstream-tracker.sh [opções]

Identificação do pacote:
  --category CAT                Categoria do pacote
  --name NAME                   Nome do pacote
  --metafile PATH               Caminho do metafile atual (opcional)
  --current-version VER         Força versão atual (pula leitura do metafile)

Comportamento:
  --provider auto|github|gitlab|sourceforge|git|http|rsync
  --regex VERSION_REGEX         Regex de versão estável (default conservador)
  --include-prerelease          Permitir pré-releases (rc/beta/alpha etc.)
  --tag-prefix STR              Remove prefixos (ex.: "v") dos rótulos upstream
  --git-strategy tags|releases  Como consultar git (default: tags)
  --download                    Baixa novas fontes e calcula sha256sums
  --verify-sig                  Tenta verificar .asc/.sig com gpg (se disponível)
  --parallel N                  Paralelismo de download (default: nproc)
  --out-dir DIR                 Base do update (default: /usr/src/adm/update/CAT/NAME)
  --apply                       Escreve metafile de update (num_builds=0)
  --dry-run                     Simula
  --json                        Saída JSON
  --log PATH                    Salva log desta execução
  --help

Notas:
- O script tenta ler o metafile original em:
  /usr/src/adm/metafiles/<cat>/<name>/metafile
- O metafile de update será escrito em:
  /usr/src/adm/update/<cat>/<name>/metafile
EOF
}

parse_cli(){
  while (($#)); do
    case "$1" in
      --category) ADM_META[category]="${2:-}"; shift 2 ;;
      --name) ADM_META[name]="${2:-}"; shift 2 ;;
      --metafile) META_PATH="${2:-}"; shift 2 ;;
      --current-version) CURRENT_VERSION_OVERRIDE="${2:-}"; shift 2 ;;
      --provider) PREFERRED_PROVIDER="${2:-auto}"; shift 2 ;;
      --regex) VER_REGEX="${2:-$VER_REGEX}"; shift 2 ;;
      --include-prerelease) INCLUDE_PRERELEASE=1; shift ;;
      --tag-prefix) TAG_PREFIX="${2:-}"; shift 2 ;;
      --git-strategy) GIT_STRATEGY="${2:-tags}"; shift 2 ;;
      --download) DOWNLOAD=1; shift ;;
      --verify-sig) VERIFY_SIG=1; shift ;;
      --parallel) PARALLEL="${2:-$PARALLEL}"; shift 2 ;;
      --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
      --apply) AUTO_APPLY=1; shift ;;
      --dry-run) DRYRUN=1; shift ;;
      --json) JSON_OUT=1; shift ;;
      --log) LOGPATH="${2:-}"; shift 2 ;;
      --help|-h) ut_usage; exit 0 ;;
      *) ut_err "opção inválida: $1"; ut_usage; exit 2 ;;
    esac
  done
  local miss=0
  for k in category name; do
    [[ -n "${ADM_META[$k]:-}" ]] || { ut_err "metadado ausente: $k"; miss=1; }
  done
  (( miss==0 )) || exit 3
}

###############################################################################
# Leitura do metafile atual
###############################################################################
# formato:
# name=programa
# version=1.2.3
# category=apps|libs|...
# run_deps=dep1,dep2
# build_deps=depA,depB
# opt_deps=depX,depY
# num_builds=0
# description=...
# homepage=https://...
# maintainer=Nome <email>
# sha256sums=sum1,sum2
# sources=url1,url2

read_current_metafile(){
  local mf="$1"
  [[ -r "$mf" ]] || { ut_warn "metafile não legível: $mf"; return 1; }
  # lê pares chave=valor (simples)
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" == \#* ]] && continue
    case "$k" in
      name) [[ -z "${ADM_META[name]}" ]] && ADM_META[name]="$v" ;;
      category) [[ -z "${ADM_META[category]}" ]] && ADM_META[category]="$v" ;;
      version) [[ -z "$CURRENT_VERSION_OVERRIDE" ]] && ADM_META[version]="$v" ;;
      homepage) ADM_META[homepage]="$v" ;;
      sources) CURRENT_SOURCES="$v" ;;
    esac
  done < <(grep -E '^[a-z0-9_]+=' "$mf" | trim)
  return 0
}

discover_metafile_path(){
  local mf="$META_PATH"
  if [[ -z "$mf" ]]; then
    mf="${ADM_META_DIR}/${ADM_META[category]}/${ADM_META[name]}/metafile"
  fi
  echo "$mf"
}

###############################################################################
# Providers: detecção & consulta
###############################################################################
# Utiliza:
# - GitHub: API (se token), fallback para git ls-remote ou HTML scraping
# - GitLab: API pública/fallback git
# - SourceForge: RSS/JSON
# - git: ls-remote tags
# - http: varre diretório listável
# - rsync: lista arquivos no módulo
#
# A heurística usa 'homepage' e/ou 'sources' do metafile para inferir.

url_host(){
  local u="$1"
  echo "$u" | sed -E 's#^[a-zA-Z0-9+.-]+://##' | cut -d/ -f1
}

guess_provider_from_urls(){
  local hp="$1" srcs="$2"
  local s="${hp:-$srcs}"
  [[ -z "$s" ]] && { echo "unknown"; return 0; }
  if grep -qi 'github.com' <<< "$s"; then echo "github"; return 0; fi
  if grep -qi 'gitlab.com' <<< "$s"; then echo "gitlab"; return 0; fi
  if grep -qi 'sourceforge.net' <<< "$s"; then echo "sourceforge"; return 0; fi
  if grep -qiE '^(git|ssh)@|\.git($| )' <<< "$s"; then echo "git"; return 0; fi
  if grep -qiE '^rsync://' <<< "$s"; then echo "rsync"; return 0; fi
  if grep -qiE '^https?://' <<< "$s"; then echo "http"; return 0; fi
  echo "unknown"
}

strip_tag_prefix(){
  local t="$1"
  local p="${TAG_PREFIX}"
  if [[ -n "$p" ]]; then
    echo "$t" | sed -E "s#^${p}##"
  else
    # comum remover 'v' simples em tags
    echo "$t" | sed -E 's/^v([0-9])/\1/'
  fi
}

is_prerelease(){
  local v="$1"
  [[ "$v" =~ (alpha|beta|rc|pre)[._-]?[0-9]* ]] && return 0 || return 1
}

is_valid_version(){
  local v="$1"
  [[ "$v" =~ $VER_REGEX ]] || return 1
  (( INCLUDE_PRERELEASE )) || { is_prerelease "$v" && return 1; }
  return 0
}

version_cmp(){ # retorna 0 se a>=b, 1 se a<b (para "é nova?")
  # usa sort -V
  local a="$1" b="$2"
  [[ "$(printf "%s\n%s\n" "$a" "$b" | sort -V | tail -n1)" == "$a" ]]
}

# Git: lista tags (ou releases via GitHub/GitLab)
git_ls_remote_tags(){
  local repo="$1"
  git ls-remote --tags "$repo" 2>/dev/null | awk '{print $2}' | sed 's#^refs/tags/##; s#\^\{\}##' | sort -u
}

github_list_releases(){
  local owner_repo="$1"   # org/repo
  if [[ -n "$GITHUB_TOKEN" ]]; then
    curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${owner_repo}/releases?per_page=100" \
      | jq -r '.[].tag_name' 2>/dev/null || true
  else
    curl -fsSL "https://api.github.com/repos/${owner_repo}/releases?per_page=100" \
      | jq -r '.[].tag_name' 2>/dev/null || true
  fi
}

gitlab_list_releases(){
  local proj="$1" # URL encoded path, ex: group%2Frepo
  curl -fsSL "https://gitlab.com/api/v4/projects/${proj}/releases?per_page=100" \
    | jq -r '.[].tag_name' 2>/dev/null || true
}

http_list_dir(){
  local base="$1" depth="${2:-1}"
  # lista como HTML/texto; extrai hrefs plausíveis
  curl -fsSL "$base" | sed -nE 's/.*href="([^"]+)".*/\1/p' | sed -E 's#\?.*$##' \
    | grep -E '\.(tar\.gz|tar\.xz|tar\.zst|tgz|txz|zip)$' || true
}

rsync_list(){
  local url="$1"
  rsync --list-only "$url" 2>/dev/null | awk '{print $NF}' || true
}

sf_list_files(){
  local path="$1" # ex: https://sourceforge.net/projects/<p>/files/latest/download
  # tentativa simples: usar RSS/JSON endpoints
  curl -fsSL "${path%/}/rss" 2>/dev/null || true
}

pick_latest_version_from_tags(){
  local tags="$1" tmp; tmp="$(tmpfile)"
  printf '%s\n' $tags | while read -r t; do
    local v; v="$(strip_tag_prefix "$t")"
    is_valid_version "$v" && echo "$v"
  done | sort -V | tail -n1
}

###############################################################################
# Baixar fontes e calcular SHA-256
###############################################################################
download_parallel(){
  local outdir="$1"; shift
  __ensure_dir "$outdir"
  local urls=("$@")
  local tool=""
  if adm_is_cmd aria2c; then tool="aria2c"
  elif adm_is_cmd wget; then tool="wget"
  elif adm_is_cmd curl; then tool="curl"
  else ut_err "nenhuma ferramenta de download encontrada (aria2c/wget/curl)"; return 2
  fi

  case "$tool" in
    aria2c)
      aria2c -x16 -s16 -j "$PARALLEL" -d "$outdir" "${urls[@]}"
      ;;
    wget)
      (cd "$outdir" && xargs -n1 -P "$PARALLEL" -I{} sh -c 'wget -q "{}"' <<< "$(printf "%s\n" "${urls[@]}")")
      ;;
    curl)
      (cd "$outdir" && xargs -n1 -P "$PARALLEL" -I{} sh -c 'f="$(basename "{}")"; curl -fsSL -o "$f" "{}"')
      ;;
  esac
}

compute_sha256sums_csv(){
  local dir="$1"
  local sums=()
  shopt -s nullglob
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    sums+=("$(sha256f "$f")")
  done
  shopt -u nullglob
  IFS=,; echo "${sums[*]}"
}

###############################################################################
# Aplicação: escrever metafile de update
###############################################################################
write_update_metafile(){
  local outdir="$1" newver="$2" sources_csv="$3" sums_csv="$4"
  local cat="${ADM_META[category]}" name="${ADM_META[name]}"
  local metaf="${outdir}/metafile"
  __ensure_dir "$(dirname "$metaf")"
  ut_info "Escrevendo metafile de update em: $metaf"
  (( DRYRUN )) && { echo "(dry-run) gerar $metaf"; return 0; }
  {
    echo "name=${name}"
    echo "version=${newver}"
    echo "category=${cat}"
    # herdamos deps do metafile atual, se existir
    if [[ -r "$CURRENT_META" ]]; then
      grep -E '^(run_deps|build_deps|opt_deps)=' "$CURRENT_META" || true
      # copia description/homepage/maintainer se presentes
      grep -E '^(description|homepage|maintainer)=' "$CURRENT_META" || true
    fi
    echo "num_builds=0"
    [[ -n "$sums_csv" ]] && echo "sha256sums=${sums_csv}"
    [[ -n "$sources_csv" ]] && echo "sources=${sources_csv}"
  } > "$metaf"
  ut_ok "metafile de update gerado."
}

###############################################################################
# JSON helpers
###############################################################################
emit_json(){
  local newver="$1" provider="$2" srcs="$3" sums="$4" status="$5" reason="$6"
  if (( JSON_OUT )) && command -v jq >/dev/null 2>&1; then
    jq -n --arg category "${ADM_META[category]}" --arg name "${ADM_META[name]}" \
      --arg current "${ADM_META[version]}" --arg new "$newver" --arg provider "$provider" \
      --arg sources "$srcs" --arg sha "$sums" --arg status "$status" --arg reason "$reason" \
      '{category:$category,name:$name,current:$current,new:$new,provider:$provider,
        sources:($sources|split(",")|map(select(length>0))), sha256s:($sha|split(",")|map(select(length>0))),
        status:$status, reason:$reason}'
  fi
}
###############################################################################
# Execução principal
###############################################################################
ut_run(){
  parse_cli "$@"

  # logging opcional
  if [[ -n "$LOGPATH" ]]; then
    exec > >(tee -a "$LOGPATH") 2>&1
  fi

  __lock "update-tracker"
  ut_hooks_run "pre-update-scan" "CATEGORY=${ADM_META[category]}" "NAME=${ADM_META[name]}"

  # determinar metafile atual
  CURRENT_META="$(discover_metafile_path)"
  CURRENT_SOURCES=""
  if [[ -n "$CURRENT_VERSION_OVERRIDE" ]]; then
    ADM_META[version]="$CURRENT_VERSION_OVERRIDE"
  else
    read_current_metafile "$CURRENT_META" || true
  fi
  [[ -n "${ADM_META[version]:-}" ]] || ADM_META[version]="0"

  # inferir provider
  local provider="$PREFERRED_PROVIDER"
  if [[ "$provider" == "auto" ]]; then
    provider="$(guess_provider_from_urls "${ADM_META[homepage]:-}" "$CURRENT_SOURCES")"
    [[ "$provider" == "unknown" ]] && provider="git"  # fallback
  fi
  ut_info "Provider: $provider"

  # obter lista de tags/artefatos candidatos
  local latest="" src_urls=() src_urls_csv="" sums_csv=""

  case "$provider" in
    github)
      # extrair owner/repo da homepage/sources
      local ref
      ref="$(printf "%s\n%s\n" "${ADM_META[homepage]:-}" "$CURRENT_SOURCES" \
            | grep -Eo 'github\.com/[^/]+/[^/ ]+' | head -n1 | sed 's#^.*github.com/##; s#.git$##')"
      if [[ -z "$ref" ]]; then ut_warn "não foi possível inferir org/repo do GitHub"; fi
      local tags
      if [[ "$GIT_STRATEGY" == "releases" ]]; then
        tags="$(github_list_releases "$ref" | tr -d '\r' || true)"
      else
        # tentar via git ls-remote
        local giturl="https://github.com/${ref}.git"
        tags="$(git ls-remote --tags "$giturl" 2>/dev/null | awk '{print $2}' | sed 's#^refs/tags/##; s#\^\{\}##' | sort -u)"
      fi
      latest="$(pick_latest_version_from_tags "$tags")"
      # artefatos padrão (tarball do GitHub)
      if [[ -n "$latest" ]]; then
        local base="https://github.com/${ref}/archive/refs/tags"
        src_urls=( "${base}/${TAG_PREFIX}${latest}.tar.gz" )
      fi
      ;;
    gitlab)
      # semelhante ao GitHub, mas via API pública para releases (se disponível)
      local proj
      proj="$(printf "%s\n%s\n" "${ADM_META[homepage]:-}" "$CURRENT_SOURCES" \
            | grep -Eo 'gitlab\.com/[^ ]+' | head -n1 | sed 's#^.*gitlab.com/##; s#/$##; s#/#%2F#g')"
      local tags
      if [[ -n "$proj" ]]; then
        tags="$(gitlab_list_releases "$proj" | tr -d '\r' || true)"
      else
        # fallback: git ls-remote se houver URL .git em sources
        local g
        g="$(printf "%s" "$CURRENT_SOURCES" | tr ',' '\n' | grep -E '\.git$' | head -n1 || true)"
        [[ -n "$g" ]] && tags="$(git_ls_remote_tags "$g")"
      fi
      latest="$(pick_latest_version_from_tags "$tags")"
      if [[ -n "$latest" && -n "$proj" ]]; then
        # tarball genérico do GitLab
        src_urls=( "https://gitlab.com/${proj//%2F//}/-/archive/${TAG_PREFIX}${latest}/${ADM_META[name]}-${latest}.tar.gz" )
      fi
      ;;
    sourceforge)
      # heurística: se houver um link base, tentar construir tarballs comuns
      # caso contrário, deixa apenas detectar versão e o empacotador ajusta URL
      # Aqui, tentamos varrer um directory listing conhecido via HTTP
      local base
      base="$(printf "%s\n%s\n" "${ADM_META[homepage]:-}" "$CURRENT_SOURCES" | grep -Eo 'sourceforge\.net/projects/[^ ]+' | head -n1 || true)"
      # Sem API fácil aqui -> cair para CURRENT_SOURCES e detectar padrão nome-versão
      latest="$(printf "%s" "$CURRENT_SOURCES" | tr ',' '\n' \
               | sed -nE 's/.*'"${ADM_META[name]}"'[-_]v?([0-9][0-9A-Za-z\.\-]*)\.(tar\.(gz|xz|zst)|tgz|txz|zip).*/\1/p' \
               | while read -r v; do is_valid_version "$v" && echo "$v"; done | sort -V | tail -n1)"
      # Se não descobrir, deixa para o usuário ajustar URL; se descobrir, mantemos primeira fonte como molde
      if [[ -n "$latest" ]]; then
        local first; first="$(printf "%s" "$CURRENT_SOURCES" | cut -d, -f1)"
        if [[ -n "$first" ]]; then
          src_urls=( "$(echo "$first" | sed -E "s/${ADM_META[name]}[-_]v?[0-9A-Za-z\.\-]+/${ADM_META[name]}-${latest}/")" )
        fi
      fi
      ;;
    git)
      # pegar URL .git do sources (ou homepage)
      local g
      g="$(printf "%s\n" "$CURRENT_SOURCES" | tr ',' '\n' | grep -E '\.git($| )' | head -n1 || true)"
      [[ -z "$g" ]] && g="${ADM_META[homepage]:-}"
      local tags; tags="$(git_ls_remote_tags "$g")"
      latest="$(pick_latest_version_from_tags "$tags")"
      # tarball genérico via git-archive não está disponível remota; deixa fontes como reempacotar via fetch script
      [[ -n "$latest" ]] || ut_warn "sem tag válida detectada em $g"
      ;;
    http)
      # varrer listagem HTTP
      local base
      base="$(printf "%s\n" "$CURRENT_SOURCES" | tr ',' '\n' | grep -E '^https?://' | head -n1)"
      if [[ -n "$base" ]]; then
        local files; files="$(http_list_dir "$base" "$HTTP_LISTING_DEPTH" || true)"
        latest="$(printf "%s" "$files" | sed -nE 's/.*'"${ADM_META[name]}"'[-_]v?([0-9][0-9A-Za-z\.\-]*)\.(tar\.(gz|xz|zst)|tgz|txz|zip).*/\1/p' \
                  | while read -r v; do is_valid_version "$v" && echo "$v"; done | sort -V | tail -n1)"
        if [[ -n "$latest" ]]; then
          src_urls=( $(printf "%s" "$files" | grep -E "${ADM_META[name]}[-_](v?)${latest}\." | head -n 4) )
        fi
      fi
      ;;
    rsync)
      local url
      url="$(printf "%s\n" "$CURRENT_SOURCES" | tr ',' '\n' | grep -E '^rsync://' | head -n1)"
      if [[ -n "$url" ]]; then
        local files; files="$(rsync_list "$url" || true)"
        latest="$(printf "%s" "$files" | sed -nE 's/.*'"${ADM_META[name]}"'[-_]v?([0-9][0-9A-Za-z\.\-]*)\.(tar\.(gz|xz|zst)|tgz|txz|zip).*/\1/p' \
                  | while read -r v; do is_valid_version "$v" && echo "$v"; done | sort -V | tail -n1)"
        if [[ -n "$latest" ]]; then
          src_urls=( $(printf "%s" "$files" | sed -nE 's#^#'"$url"'#p' | grep -E "${ADM_META[name]}[-_](v?)${latest}\." | head -n 4) )
        fi
      fi
      ;;
    *)
      ut_warn "provider desconhecido; tente --provider git|github|gitlab|http|rsync|sourceforge"
      ;;
  esac

  if [[ -z "$latest" ]]; then
    ut_warn "não foi possível detectar versão upstream automaticamente."
    emit_json "" "$provider" "" "" "noop" "no-latest-detected" || true
    __unlock; exit 0
  fi

  # comparação
  local cur="${ADM_META[version]}"
  if version_cmp "$cur" "$latest"; then
    ut_info "Versão atual (${cur}) já é a mais nova (>= ${latest})."
    emit_json "$latest" "$provider" "" "" "noop" "current-is-latest" || true
    __unlock; exit 0
  fi

  ut_ok "Nova versão encontrada: ${latest} (atual: ${cur})"

  # downloads/sums
  if (( DOWNLOAD )) && ((${#src_urls[@]}>0)); then
    local dlbase="${ADM_STATE_DIR}/downloads/${ADM_META[category]}/${ADM_META[name]}/${latest}"
    (( DRYRUN )) || __ensure_dir "$dlbase"
    ut_info "Baixando fontes em paralelo (${#src_urls[@]} arquivos)…"
    if (( DRYRUN )); then
      printf "%s\n" "${src_urls[@]}" | sed 's/^/(dry-run) download: /'
    else
      download_parallel "$dlbase" "${src_urls[@]}"
      if (( VERIFY_SIG )); then
        if adm_is_cmd gpg; then
          shopt -s nullglob
          for a in "$dlbase"/*; do
            for sig in "${a}.asc" "${a}.sig"; do
              if curl -fsSL -o "$sig" "${a}.asc" 2>/dev/null || curl -fsSL -o "$sig" "${a}.sig" 2>/dev/null; then
                gpg --verify "$sig" "$a" >/dev/null 2>&1 || ut_warn "falha ao verificar assinatura de $(basename "$a")"
              fi
            done
          done
          shopt -u nullglob
        else
          ut_warn "gpg indisponível; pulando verificação de assinatura"
        fi
      fi
    fi
    if (( DRYRUN )); then
      sums_csv=""
      src_urls_csv="$(IFS=,; echo "${src_urls[*]}")"
    else
      sums_csv="$(compute_sha256sums_csv "$dlbase")"
      # normaliza como URLs originais
      src_urls_csv="$(IFS=,; echo "${src_urls[*]}")"
    fi
  fi

  # diretório de saída
  local outdir="$OUT_DIR"
  if [[ -z "$outdir" ]]; then
    outdir="${UPDATE_DIR}/${ADM_META[category]}/${ADM_META[name]}"
  fi
  __ensure_dir "$outdir"

  ut_hooks_run "post-update-scan" "NEW_VERSION=${latest}" "PROVIDER=${provider}"

  # aplicar (escrever metafile update)
  if (( AUTO_APPLY )); then
    ut_hooks_run "pre-update-apply" "OUTDIR=$outdir"
    write_update_metafile "$outdir" "$latest" "${src_urls_csv}" "${sums_csv}"
    ut_hooks_run "post-update-apply" "OUTDIR=$outdir" "NEW_VERSION=${latest}"
  fi

  emit_json "$latest" "$provider" "${src_urls_csv}" "${sums_csv}" "ok" "" || true
  __unlock
  ut_ok "Concluído."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ut_run "$@"
fi
