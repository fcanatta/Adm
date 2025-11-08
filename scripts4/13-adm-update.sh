#!/usr/bin/env bash
# 13-adm-update.part1.sh
# Descobre a maior versão upstream (git/https/ftp/GitHub/GitLab/SF), valida artefatos
# e gera metafile em /usr/src/adm/update/<cat>/<name>.
###############################################################################
# Guardas e pré-requisitos mínimos
###############################################################################
if [[ -n "${ADM_UPDATE_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_UPDATE_LOADED_PART1=1

for _m in ADM_CONF_LOADED ADM_LIB_LOADED; do
  if [[ -z "${!_m:-}" ]]; then
    echo "ERRO: 13-adm-update requer módulos básicos carregados (00/01). Faltando: ${_m}" >&2
    return 2 2>/dev/null || exit 2
  fi
done

: "${ADM_STATE_ROOT:=/usr/src/adm/state}"
: "${ADM_CACHE_ROOT:=/usr/src/adm/cache}"
: "${ADM_TMP_ROOT:=/usr/src/adm/tmp}"
: "${ADM_METAFILE_ROOT:=/usr/src/adm/metafile}"
: "${ADM_UPDATE_ROOT:=/usr/src/adm/update}"
: "${ADM_OFFLINE:=false}"

upd_err()  { adm_err "$*"; }
upd_warn() { adm_warn "$*"; }
upd_info() { adm_log INFO "update" "${U_CTX_NAME:-pkg}" "$*"; }

###############################################################################
# Contexto e defaults
###############################################################################
declare -Ag UPD=(
  [offline]="${ADM_OFFLINE}" [timeout]=30 [retries]=3 [proxy]="" [allow_pr]="false"
  [policy]="same-major" [prefer]="tarzst,taxz,targz,zip,any" [accept]="" [reject]=""
  [require_checksum]="false" [print_json]="false" [token]="" [format_override]=""
)
declare -Ag U_SRC=()   # pistas de origem
declare -Ag MF=()      # campos do metafile atual
declare -Ag CAND=()    # vencedor (campos)
declare -Ag PATHS=()   # logs e tmp

_upd_require_cmd() {
  local miss=()
  for c in curl git awk sed grep tar sha256sum; do
    command -v "$c" >/dev/null 2>&1 || miss+=("$c")
  done
  if ((${#miss[@]})); then
    upd_err "ferramentas ausentes: ${miss[*]}"
    return 2
  fi
}
_upd_prepare_paths() {
  local cat="$1" name="$2"
  PATHS[base]="${ADM_STATE_ROOT%/}/logs/update/${cat}/${name}"
  mkdir -p -- "${PATHS[base]}" "${ADM_TMP_ROOT%/}" || { upd_err "falha ao criar diretórios de log/tmp"; return 3; }
  PATHS[discover]="${PATHS[base]}/discover.log"
  PATHS[select]="${PATHS[base]}/select.log"
  PATHS[download]="${PATHS[base]}/download.log"
  PATHS[metafile]="${PATHS[base]}/metafile.log"
}

###############################################################################
# Utilidades de rede e I/O
###############################################################################
_curl_common_args() {
  local args=("-L" "--fail" "--silent" "--show-error" "--max-time" "${UPD[timeout]}" "--retry" "${UPD[retries]}" "--retry-connrefused")
  [[ -n "${UPD[proxy]}" ]] && args+=("--proxy" "${UPD[proxy]}")
  echo "${args[@]}"
}
_fetch_url_head() {
  # _fetch_url_head <url> -> imprime HTTP code e cabeçalhos em stdout (ou nada em offline)
  [[ "${UPD[offline]}" == "true" ]] && return 4
  local url="$1"
  curl -I "$url" $(_curl_common_args) || return 4
}
_fetch_url() {
  # _fetch_url <url> <outfile>
  [[ "${UPD[offline]}" == "true" ]] && return 4
  local url="$1" out="$2"
  curl "$url" -o "$out" $(_curl_common_args)
}
_fetch_json() {
  # _fetch_json <url> -> stdout
  [[ "${UPD[offline]}" == "true" ]] && return 4
  local url="$1"
  curl "$url" $(_curl_common_args)
}

###############################################################################
# Metafile atual: leitura (via módulo 04, se disponível) ou parser simples
###############################################################################
_upd_metafile_load() {
  # _upd_metafile_load <cat> <name> -> preenche MF[]
  local cat="$1" name="$2"
  local mf="${ADM_METAFILE_ROOT%/}/${cat}/${name}/metafile"
  if [[ -r "$mf" ]] && command -v adm_metafile_get >/dev/null 2>&1; then
    MF[name]="$(adm_metafile_get "$mf" name)"
    MF[version]="$(adm_metafile_get "$mf" version)"
    MF[category]="$(adm_metafile_get "$mf" category)"
    MF[build_type]="$(adm_metafile_get "$mf" build_type)"
    MF[run_deps]="$(adm_metafile_get "$mf" run_deps)"
    MF[build_deps]="$(adm_metafile_get "$mf" build_deps)"
    MF[opt_deps]="$(adm_metafile_get "$mf" opt_deps)"
    MF[description]="$(adm_metafile_get "$mf" description)"
    MF[homepage]="$(adm_metafile_get "$mf" homepage)"
    MF[maintainer]="$(adm_metafile_get "$mf" maintainer)"
    MF[sources]="$(adm_metafile_get "$mf" sources)"
    MF[sha256sums]="$(adm_metafile_get "$mf" sha256sums)"
  elif [[ -r "$mf" ]]; then
    MF[name]="$(sed -n 's/^name=//p' "$mf" | head -n1)"
    MF[version]="$(sed -n 's/^version=//p' "$mf" | head -n1)"
    MF[category]="$(sed -n 's/^category=//p' "$mf" | head -n1)"
    MF[build_type]="$(sed -n 's/^build_type=//p' "$mf" | head -n1)"
    MF[run_deps]="$(sed -n 's/^run_deps=//p' "$mf" | head -n1)"
    MF[build_deps]="$(sed -n 's/^build_deps=//p' "$mf" | head -n1)"
    MF[opt_deps]="$(sed -n 's/^opt_deps=//p' "$mf" | head -n1)"
    MF[description]="$(sed -n 's/^description=//p' "$mf" | head -n1)"
    MF[homepage]="$(sed -n 's/^homepage=//p' "$mf" | head -n1)"
    MF[maintainer]="$(sed -n 's/^maintainer=//p' "$mf" | head -n1)"
    MF[sources]="$(sed -n 's/^sources=//p' "$mf" | head -n1)"
    MF[sha256sums]="$(sed -n 's/^sha256sums=//p' "$mf" | head -n1)"
  else
    upd_err "metafile não encontrado: $mf"
    return 1
  fi
  # sanity
  [[ -n "${MF[name]}" && -n "${MF[category]}" ]] || { upd_err "metafile inválido (name/category vazios)"; return 1; }
  return 0
}

###############################################################################
# Versões: normalização, comparação e políticas
###############################################################################
# Representaremos versões como:
# - chave de ordenação: "S;M;N;P;PRETYPE;PRENUM;CALVER;DATE"
#   S = semver? (1/0). Para datas/calver S=0 e usamos campos apropriados.
# Pré-releases: rank: dev=1, alpha=2, beta=3, rc=4, none=9
_ver_pr_rank() {
  case "$1" in
    dev|snapshot) echo 1;;
    alpha) echo 2;;
    beta) echo 3;;
    rc) echo 4;;
    "") echo 9;;
    *) echo 5;;
  esac
}
_ver_trim_v() { echo "$1" | sed 's/^[vV]//' ; }

_ver_key() {
  # _ver_key <version> -> imprime chave
  local v="$(_ver_trim_v "$1")"
  # calver YYYY.MM.DD
  if [[ "$v" =~ ^([0-9]{4})[._-]([0-9]{1,2})[._-]([0-9]{1,2})$ ]]; then
    printf "0;0;0;0;9;0;%04d%02d%02d;0\n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  # data YYYYMMDD
  if [[ "$v" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})$ ]]; then
    printf "0;0;0;0;9;0;%s;0\n" "$v"
    return 0
  fi
  # semver com pre-release: X.Y.Z[-preN]
  local base pretype pren
  if [[ "$v" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?([.-]?(rc|beta|alpha|dev)[._-]?([0-9]+)?)?$ ]]; then
    local M="${BASH_REMATCH[1]}" N="${BASH_REMATCH[2]}" P="${BASH_REMATCH[4]}"
    pretype="${BASH_REMATCH[6]}"; pren="${BASH_REMATCH[7]}"
    [[ -z "$P" ]] && P=0
    [[ -z "$pren" ]] && pren=0
    local r="$(_ver_pr_rank "$pretype")"
    printf "1;%d;%d;%d;%d;%d;0;0\n" "$M" "$N" "$P" "$r" "$pren"
    return 0
  fi
  # fallback: extrair números na ordem
  local nums; nums=($(echo "$v" | grep -oE '[0-9]+' || echo "0"))
  local M="${nums[0]:-0}" N="${nums[1]:-0}" P="${nums[2]:-0}"
  printf "1;%d;%d;%d;9;0;0;0\n" "$M" "$N" "$P"
}

_ver_cmp() {
  # _ver_cmp <a> <b> -> return 0 if a==b, 1 if a>b, 2 if a<b
  local ka kb
  ka="$(_ver_key "$1")"; kb="$(_ver_key "$2")"
  if [[ "$ka" == "$kb" ]]; then return 0; fi
  # comparar campo a campo
  local IFS=';' a=($ka) b=($kb)
  for i in "${!a[@]}"; do
    if ((10#${a[$i]} > 10#${b[$i]})); then return 1; fi
    if ((10#${a[$i]} < 10#${b[$i]})); then return 2; fi
  done
  return 0
}

_policy_allow_version() {
  # _policy_allow_version <current> <candidate> -> 0 se permitido
  local cur="$1" cand="$2"
  local kc kn; kc="$(_ver_key "$cur")"; kn="$(_ver_key "$cand")"
  # extrair major/minor/patch apenas quando semver (S==1)
  local IFS=';' a=($kc) b=($kn)
  if [[ "${UPD[policy]}" == "patch-only" || "${UPD[policy]}" == "minor-only" || "${UPD[policy]}" == "same-major" ]]; then
    if [[ "${a[0]}" -eq 1 && "${b[0]}" -eq 1 ]]; then
      local M1="${a[1]}" m1="${a[2]}" p1="${a[3]}"
      local M2="${b[1]}" m2="${b[2]}" p2="${b[3]}"
      case "${UPD[policy]}" in
        patch-only) [[ "$M1" -eq "$M2" && "$m1" -eq "$m2" && "$p2" -ge "$p1" ]] || return 1;;
        minor-only) [[ "$M1" -eq "$M2" && "$m2" -ge "$m1" ]] || return 1;;
        same-major) [[ "$M1" -eq "$M2" ]] || return 1;;
      esac
    fi
  fi
  # pré-release?
  local rk; rk="$(_ver_key "$cand" | awk -F';' '{print $5}')"
  if [[ "$rk" -lt 9 && "${UPD[allow_pr]}" != "true" ]]; then
    return 1
  fi
  return 0
}

###############################################################################
# Representação de candidatos e agregação
###############################################################################
# Representamos cada candidato como linha TSV:
# version \t url \t format \t source \t published \t size \t checksum_url
_candidates_file() { echo "${ADM_TMP_ROOT%/}/upd-candidates-$$.tsv"; }
_candidates_add() {
  # _candidates_add <file> <version> <url> <format> <source> <published> <size> <sumurl>
  local f="$1"; shift
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$4" "${5:-}" "${6:-0}" "${7:-}" >> "$f"
}
_format_from_url() {
  case "$1" in
    *.tar.zst|*.tzst) echo "tarzst";;
    *.tar.xz) echo "tarxz";;
    *.tar.gz|*.tgz) echo "targz";;
    *.zip) echo "zip";;
    *.tar.bz2|*.tbz2) echo "tarbz2";;
    *) echo "unknown";;
  esac
}
_matches_globs() {
  # _matches_globs <name> "<glob1,glob2>"
  local name="$1" gl="$2"; [[ -z "$gl" ]] && return 1
  local IFS=','; read -r -a arr <<<"$gl"
  for g in "${arr[@]}"; do
    [[ -z "$g" ]] && continue
    if [[ "$name" == $g ]]; then return 0; fi
  done
  return 1
}
# 13-adm-update.part2.sh
# Descoberta: git, GitHub, GitLab, SourceForge, HTTP/FTP
if [[ -n "${ADM_UPDATE_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_UPDATE_LOADED_PART2=1
###############################################################################
# Descoberta em Git (ls-remote)
###############################################################################
_disc_git_lsremote() {
  # _disc_git_lsremote <repo_url> <name> <candidates_file>
  [[ "${UPD[offline]}" == "true" ]] && return 0
  local repo="$1" name="$2" out="$3"
  adm_step "$name" "" "git ls-remote (tags)"
  local lines
  if ! lines="$(git ls-remote --tags --refs "$repo" 2>>"${PATHS[discover]}")"; then
    upd_warn "git ls-remote falhou para $repo (veja: ${PATHS[discover]})"
    return 0
  fi
  # parse tags -> versões
  while read -r hash ref; do
    [[ -z "$ref" ]] && continue
    local tag="${ref##*/}"
    local v="${tag#v}"
    # filtrar pré-lançamentos se necessário depois; por ora coletar
    # estimar tarball padrão para hosts comuns
    local url=""
    case "$repo" in
      *github.com*/*.git)
        local base="${repo%.git}"
        url="${base}/archive/refs/tags/${tag}.tar.gz"
        ;;
      *gitlab.com*/*.git)
        local base="${repo%.git}"
        url="${base}/-/archive/${tag}/${name}-${tag}.tar.gz"
        ;;
      *)
        url="" # desconhecido; ainda assim registrar versão (sem URL)
        ;;
    esac
    local fmt; fmt="$(_format_from_url "$url")"
    _candidates_add "$out" "$v" "$url" "$fmt" "git" "" 0 ""
  done <<<"$lines"
}

###############################################################################
# GitHub (API e fallback)
###############################################################################
_disc_github() {
  # _disc_github <org/repo> <name> <candidates_file>
  [[ "${UPD[offline]}" == "true" ]] && return 0
  local project="$1" name="$2" out="$3"
  local api="https://api.github.com/repos/${project}"
  local hdr=()
  [[ -n "${UPD[token]}" || -n "${GITHUB_TOKEN:-}" ]] && hdr+=(-H "Authorization: Bearer ${UPD[token]:-${GITHUB_TOKEN}}")
  # Releases
  local data
  data="$(_fetch_json "${api}/releases?per_page=100" 2>>"${PATHS[discover]}" | cat)" || true
  if [[ -n "$data" && "$(echo "$data" | head -c 1)" == "[" ]]; then
    if command -v jq >/dev/null 2>&1; then
      echo "$data" | jq -r '.[] | select((.draft|not) and (.prerelease|not)) | .tag_name + "\t" + ( .assets[0].browser_download_url? // "" ) + "\t" + ( .published_at // "" )' 2>>"${PATHS[discover]}" | \
      while IFS=$'\t' read -r tag url pub; do
        [[ -z "$tag" ]] && continue
        local v="${tag#v}"
        local fmt="$(_format_from_url "$url")"
        [[ -z "$url" ]] && url="https://github.com/${project}/archive/refs/tags/${tag}.tar.gz" && fmt="targz"
        _candidates_add "$out" "$v" "$url" "$fmt" "github" "$pub" 0 ""
      done
    else
      # sem jq — procurar por "tag_name" naive
      echo "$data" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"tag_name":[[:space:]]*"\(.*\)".*/\1/' | while read -r tag; do
        local v="${tag#v}" url="https://github.com/${project}/archive/refs/tags/${tag}.tar.gz"
        _candidates_add "$out" "$v" "$url" "targz" "github" "" 0 ""
      done
    fi
    return 0
  fi
  # Fallback: tags (sem assets)
  local tags
  tags="$(_fetch_json "https://api.github.com/repos/${project}/tags?per_page=100" | cat)" || true
  if [[ -n "$tags" ]]; then
    if command -v jq >/dev/null 2>&1; then
      echo "$tags" | jq -r '.[].name' | while read -r tag; do
        local v="${tag#v}" url="https://github.com/${project}/archive/refs/tags/${tag}.tar.gz"
        _candidates_add "$out" "$v" "$url" "targz" "github" "" 0 ""
      done
    else
      echo "$tags" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"name":[[:space:]]*"\(.*\)".*/\1/' | while read -r tag; do
        local v="${tag#v}" url="https://github.com/${project}/archive/refs/tags/${tag}.tar.gz"
        _candidates_add "$out" "$v" "$url" "targz" "github" "" 0 ""
      done
    fi
  fi
}

###############################################################################
# GitLab
###############################################################################
_disc_gitlab() {
  # _disc_gitlab <org/repo or url-encoded id> <name> <candidates_file>
  [[ "${UPD[offline]}" == "true" ]] && return 0
  local project="$1" name="$2" out="$3"
  local api="https://gitlab.com/api/v4/projects/${project}"
  local data; data="$(_fetch_json "${api}/releases" 2>>"${PATHS[discover]}" | cat)" || true
  if [[ -n "$data" && "$(echo "$data" | head -c 1)" == "[" ]]; then
    if command -v jq >/dev/null 2>&1; then
      echo "$data" | jq -r '.[] | .tag_name + "\t" + (.released_at // "")' | while IFS=$'\t' read -r tag pub; do
        local v="${tag#v}" url="https://gitlab.com/${project}/-/archive/${tag}/${name}-${tag}.tar.gz"
        _candidates_add "$out" "$v" "$url" "targz" "gitlab" "$pub" 0 ""
      done
    else
      echo "$data" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"tag_name":[[:space:]]*"\(.*\)".*/\1/' | while read -r tag; do
        local v="${tag#v}" url="https://gitlab.com/${project}/-/archive/${tag}/${name}-${tag}.tar.gz"
        _candidates_add "$out" "$v" "$url" "targz" "gitlab" "" 0 ""
      done
    fi
  else
    # fallback tags
    local tags; tags="$(_fetch_json "${api}/repository/tags?per_page=100" | cat)" || true
    if [[ -n "$tags" ]]; then
      if command -v jq >/dev/null 2>&1; then
        echo "$tags" | jq -r '.[].name' | while read -r tag; do
          local v="${tag#v}" url="https://gitlab.com/${project}/-/archive/${tag}/${name}-${tag}.tar.gz"
          _candidates_add "$out" "$v" "$url" "targz" "gitlab" "" 0 ""
        done
      else
        echo "$tags" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"name":[[:space:]]*"\(.*\)".*/\1/' | while read -r tag; do
          local v="${tag#v}" url="https://gitlab.com/${project}/-/archive/${tag}/${name}-${tag}.tar.gz"
          _candidates_add "$out" "$v" "$url" "targz" "gitlab" "" 0 ""
        done
      fi
    fi
  fi
}

###############################################################################
# SourceForge (HTML simples / RSS / redirect)
###############################################################################
_disc_sourceforge() {
  # _disc_sourceforge <project[/path]> <name> <candidates_file>
  [[ "${UPD[offline]}" == "true" ]] && return 0
  local proj="$1" name="$2" out="$3"
  local base="https://sourceforge.net/projects/${proj}/files"
  local html; html="$(_fetch_json "$base" 2>>"${PATHS[discover]}" | cat)" || true
  [[ -z "$html" ]] && return 0
  # procurar links para arquivos "name-x.y.z.tar.*"
  echo "$html" | grep -Eo "${name}[-_][0-9][0-9a-zA-Z\.\-]*\.tar\.(zst|xz|gz|bz2)|${name}[-_][0-9][0-9a-zA-Z\.\-]*\.zip" | sort -u | while read -r f; do
    local v="${f#$name-}"; v="${v#$name_}"; v="${v%%.tar.*}"; v="${v%%.zip}"
    local url="https://downloads.sourceforge.net/project/${proj}/${f}"
    local fmt="$(_format_from_url "$url")"
    _candidates_add "$out" "$v" "$url" "$fmt" "sourceforge" "" 0 ""
  done
}

###############################################################################
# HTTP/FTP genérico (listagem/autoindex simples)
###############################################################################
_disc_http_index() {
  # _disc_http_index <url> <name> <candidates_file>
  [[ "${UPD[offline]}" == "true" ]] && return 0
  local url="$1" name="$2" out="$3"
  local html; html="$(_fetch_json "$url" 2>>"${PATHS[discover]}" | cat)" || true
  [[ -z "$html" ]] && return 0
  echo "$html" | grep -Eo "${name}[-_][0-9][0-9a-zA-Z\.\-]*\.tar\.(zst|xz|gz|bz2)|${name}[-_][0-9][0-9a-zA-Z\.\-]*\.zip" | sort -u | while read -r f; do
    local v="${f#$name-}"; v="${v#$name_}"; v="${v%%.tar.*}"; v="${v%%.zip}"
    local u="${url%/}/$f"
    local fmt="$(_format_from_url "$u")"
    _candidates_add "$out" "$v" "$u" "$fmt" "http" "" 0 ""
  done
}

_disc_ftp_list() {
  # _disc_ftp_list <url> <name> <candidates_file>
  [[ "${UPD[offline]}" == "true" ]] && return 0
  local url="$1" name="$2" out="$3"
  local lst; lst="$(_fetch_json "$url" 2>>"${PATHS[discover]}" | cat)" || true
  [[ -z "$lst" ]] && return 0
  echo "$lst" | grep -Eo "${name}[-_][0-9][0-9a-zA-Z\.\-]*\.tar\.(zst|xz|gz|bz2)|${name}[-_][0-9][0-9a-zA-Z\.\-]*\.zip" | sort -u | while read -r f; do
    local v="${f#$name-}"; v="${v#$name_}"; v="${v%%.tar.*}"; v="${v%%.zip}"
    local u="${url%/}/$f"
    local fmt="$(_format_from_url "$u")"
    _candidates_add "$out" "$v" "$u" "$fmt" "ftp" "" 0 ""
  done
}

###############################################################################
# Orquestração de descoberta
###############################################################################
_upd_discover_all() {
  # _upd_discover_all <cat> <name> -> retorna caminho do arquivo de candidatos (TSV)
  local cat="$1" name="$2"
  local f; f="$(_candidates_file)"
  : > "$f" 2>/dev/null || { upd_err "não foi possível criar arquivo temporário de candidatos"; return 3; }

  # Hints explícitos primeiro
  [[ -n "${U_SRC[github]}" ]] && _disc_github "${U_SRC[github]}" "$name" "$f"
  [[ -n "${U_SRC[gitlab]}" ]] && _disc_gitlab "${U_SRC[gitlab]}" "$name" "$f"
  [[ -n "${U_SRC[git]}"    ]] && _disc_git_lsremote "${U_SRC[git]}" "$name" "$f"
  [[ -n "${U_SRC[url]}"    ]] && _disc_http_index "${U_SRC[url]}" "$name" "$f"
  [[ -n "${U_SRC[ftp]}"    ]] && _disc_ftp_list "${U_SRC[ftp]}" "$name" "$f"
  [[ -n "${U_SRC[sourceforge]}" ]] && _disc_sourceforge "${U_SRC[sourceforge]}" "$name" "$f"

  # se não houver hints, inferir do metafile:
  if [[ ! -s "$f" ]]; then
    local hp="${MF[homepage]}"
    local srcs="${MF[sources]}"
    if [[ "$hp" =~ github\.com/([^/]+/[^/]+) ]]; then
      _disc_github "${BASH_REMATCH[1]}" "$name" "$f"
    elif [[ "$hp" =~ gitlab\.com/([^/]+/[^/]+) ]]; then
      _disc_gitlab "${BASH_REMATCH[1]//\//%2F}" "$name" "$f"
    elif [[ "$hp" =~ sourceforge\.net/projects/([^[:space:]]+) ]]; then
      _disc_sourceforge "${BASH_REMATCH[1]}" "$name" "$f"
    elif [[ "$hp" =~ \.git$ ]]; then
      _disc_git_lsremote "$hp" "$name" "$f"
    fi
    # fontes atuais → subir um nível do diretório
    if [[ -n "$srcs" ]]; then
      IFS=',' read -r -a arr <<<"$srcs"
      for u in "${arr[@]}"; do
        u="${u//[[:space:]]/}"
        if [[ "$u" =~ ^git(\+|://) ]]; then
          _disc_git_lsremote "$u" "$name" "$f"
        elif [[ "$u" =~ ^ftp:// ]]; then
          _disc_ftp_list "${u%/*}" "$name" "$f"
        elif [[ "$u" =~ ^https?:// ]]; then
          _disc_http_index "${u%/*}" "$name" "$f"
        fi
      done
    fi
  fi

  echo "$f"
}

###############################################################################
# Seleção do melhor candidato
###############################################################################
_upd_select_best() {
  # _upd_select_best <candidates.tsv> -> popula CAND[]
  local f="$1"
  [[ -s "$f" ]] || { upd_err "nenhum candidato encontrado (veja: ${PATHS[discover]})"; return 7; }

  # filtros accept/reject e formatos preferidos
  local accepted=()
  while IFS=$'\t' read -r ver url fmt src pub size sumurl; do
    [[ -z "$ver" ]] && continue
    # aceitar sem URL? (pouco útil) — preferir linhas com URL
    [[ -z "$url" ]] && continue
    local base="$(basename -- "$url")"
    if _matches_globs "$base" "${UPD[reject]}"; then continue; fi
    if [[ -n "${UPD[accept]}" ]] && ! _matches_globs "$base" "${UPD[accept]}"; then continue; fi
    # política de versão
    if ! _policy_allow_version "${MF[version]}" "$ver"; then
      continue
    fi
    accepted+=("$ver"$'\t'"$url"$'\t'"$fmt"$'\t'"$src"$'\t'"$pub"$'\t'"$size"$'\t'"$sumurl")
  done < "$f"

  ((${#accepted[@]})) || { upd_err "nenhum candidato elegível pela política/filtros (veja: ${PATHS[select]})"; return 5; }

  # ordenar por versão (desc) e preferência de formato
  local pref_order=()
  IFS=',' read -r -a pref_order <<<"${UPD[prefer]}"
  # construir tabela auxiliar com chave sortável
  {
    for line in "${accepted[@]}"; do
      IFS=$'\t' read -r ver url fmt src pub size sumurl <<<"$line"
      local key; key="$(_ver_key "$ver")"
      # ranking de formato
      local rank=99 i=0
      for pf in "${pref_order[@]}"; do
        if [[ "$fmt" == "$pf" ]]; then rank="$i"; break; fi
        i=$((i+1))
      done
      printf "%s\t%02d\t%s\t%s\t%s\t%s\t%s\t%s\n" "$key" "$rank" "$ver" "$url" "$fmt" "$src" "$pub" "$sumurl"
    done
  } | sort -r -t $'\t' -k1,1 -k2,2n > "${PATHS[select]}"

  # pegar o topo
  IFS=$'\t' read -r _key _r ver url fmt src pub sumurl < "${PATHS[select]}"

  CAND[version]="$ver"; CAND[url]="$url"; CAND[format]="$fmt"; CAND[source]="$src"; CAND[published]="$pub"; CAND[sumurl]="$sumurl"
  return 0
}
# 13-adm-update.part3.sh
# Download/sha, verificação de tar, geração do metafile e CLI
if [[ -n "${ADM_UPDATE_LOADED_PART3:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_UPDATE_LOADED_PART3=1
###############################################################################
# Download, checksum e segurança do tarball
###############################################################################
_upd_download_artifact() {
  # _upd_download_artifact -> preenche CAND[file] e CAND[sha256]
  local url="${CAND[url]}"
  local out="${ADM_TMP_ROOT%/}/$(basename -- "$url")"
  # usar 03-adm-download se disponível
  if command -v adm_download_url >/dev/null 2>&1; then
    if ! adm_download_url "$url" "$out" >>"${PATHS[download]}" 2>&1; then
      upd_err "download falhou: $url (veja: ${PATHS[download]})"; return 4;
    fi
  else
    _fetch_url "$url" "$out" >>"${PATHS[download]}" 2>&1 || { upd_err "download falhou: $url (veja: ${PATHS[download]})"; return 4; }
  fi
  CAND[file]="$out"

  # checksum: tentar sumurl → senão calcular local
  local sum=""
  if [[ -n "${CAND[sumurl]}" ]]; then
    local sumsfile="${out}.sha256"
    if _fetch_url "${CAND[sumurl]}" "$sumsfile" >>"${PATHS[download]}" 2>&1; then
      sum="$(grep -Eo '^[0-9a-fA-F]{64}' "$sumsfile" | head -n1)"
    fi
  fi
  if [[ -z "$sum" ]]; then
    sum="$(sha256sum "$out" | awk '{print $1}')"
    if [[ "${UPD[require_checksum]}" == "true" ]]; then
      upd_err "checksum upstream ausente e --require-checksum ativo"; return 6;
    fi
  fi
  CAND[sha256]="$sum"
  return 0
}

_upd_tar_safe() {
  # _upd_tar_safe <file>
  local f="$1"
  local list out rc=0
  case "$f" in
    *.tar.zst|*.tzst) out="$(unzstd -c "$f" 2>>"${PATHS[download]}" | tar -tf - 2>>"${PATHS[download]}")" || rc=$?;;
    *.tar.xz)         out="$(xz -dc "$f" 2>>"${PATHS[download]}" | tar -tf - 2>>"${PATHS[download]}")" || rc=$?;;
    *.tar.gz|*.tgz)   out="$(gzip -dc "$f" 2>>"${PATHS[download]}" | tar -tf - 2>>"${PATHS[download]}")" || rc=$?;;
    *.tar.bz2|*.tbz2) out="$(bzip2 -dc "$f" 2>>"${PATHS[download]}" | tar -tf - 2>>"${PATHS[download]}")" || rc=$?;;
    *.zip)            out="$(unzip -Z1 "$f" 2>>"${PATHS[download]}")" || rc=$?;;
    *)                out="$(tar -tf "$f" 2>>"${PATHS[download]}")" || rc=$?;;
  esac
  (( rc == 0 )) || { upd_err "não foi possível listar conteúdo do artefato (veja: ${PATHS[download]})"; return 6; }
  # verificar traversal/absolutos
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ "$p" == /* ]] && { upd_err "tarball inseguro: caminho absoluto ($p)"; return 6; }
    [[ "$p" == *".."* ]] && { upd_err "tarball inseguro: path traversal ($p)"; return 6; }
    [[ "$p" =~ [[:cntrl:]] ]] && { upd_err "tarball inseguro: caractere de controle ($p)"; return 6; }
  done <<<"$out"
  return 0
}

###############################################################################
# Geração do metafile em update/
###############################################################################
_upd_write_metafile_update() {
  # _upd_write_metafile_update <cat> <name>
  local cat="$1" name="$2"
  local dir="${ADM_UPDATE_ROOT%/}/${cat}/${name}"
  local mf="${dir}/metafile"
  mkdir -p -- "${dir}/hooks" "${dir}/patches" || { upd_err "não foi possível criar diretório de update: $dir"; return 3; }

  # normalizar deps (ordenar, deduplicar)
  _norm_csv() { local s="$1"; IFS=',' read -r -a a <<<"$s"; declare -A seen=(); local out=(); for e in "${a[@]}"; do e="${e//[[:space:]]/}"; [[ -z "$e" ]] && continue; [[ -n "${seen[$e]}" ]] && continue; seen["$e"]=1; out+=("$e"); done; printf "%s" "$(printf "%s\n" "${out[@]}" | sed '/^$/d' | sort | paste -sd, -)"; }
  local run="$(_norm_csv "${MF[run_deps]}")"
  local bld="$(_norm_csv "${MF[build_deps]}")"
  local opt="$(_norm_csv "${MF[opt_deps]}")"

  {
    echo "name=${MF[name]}"
    echo "version=${CAND[version]}"
    echo "category=${MF[category]}"
    echo "build_type=${MF[build_type]}"
    echo "run_deps=${run}"
    echo "build_deps=${bld}"
    echo "opt_deps=${opt}"
    echo "num_builds=0"
    echo "description=${MF[description]}"
    echo "homepage=${MF[homepage]}"
    echo "maintainer=${MF[maintainer]}"
    echo "sha256sums=${CAND[sha256]}"
    echo "sources=${CAND[url]}"
  } > "$mf" 2>>"${PATHS[metafile]}" || { upd_err "falha ao escrever $mf (veja: ${PATHS[metafile]})"; return 3; }

  echo "$mf"
}

###############################################################################
# CLI: check, generate, adopt, sources
###############################################################################
_usage() {
  cat >&2 <<EOF
uso:
  $0 check <cat> <name> [--allow-prerelease] [--allow-major|--same-major|--minor-only|--patch-only]
             [--github org/repo] [--gitlab org/repo] [--git url] [--url http://...] [--ftp ftp://...]
             [--sourceforge project/path] [--timeout N] [--retries N] [--proxy URL] [--prefer list]
             [--accept globs] [--reject globs] [--require-checksum] [--print-json]

  $0 generate <cat> <name> [mesmas flags de check]
  $0 adopt --name <name> --category <cat> (--url|--git|--github|--gitlab|--sourceforge <ref>) [flags]
  $0 sources <cat> <name> [flags]
EOF
}

_parse_common_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --offline) UPD[offline]=true; shift;;
      --timeout) UPD[timeout]="$2"; shift 2;;
      --retries) UPD[retries]="$2"; shift 2;;
      --proxy)   UPD[proxy]="$2"; shift 2;;
      --allow-prerelease) UPD[allow_pr]=true; shift;;
      --allow-major) UPD[policy]="allow-major"; shift;;
      --same-major)  UPD[policy]="same-major"; shift;;
      --minor-only)  UPD[policy]="minor-only"; shift;;
      --patch-only)  UPD[policy]="patch-only"; shift;;
      --prefer)  UPD[prefer]="$2"; shift 2;;
      --accept)  UPD[accept]="$2"; shift 2;;
      --reject)  UPD[reject]="$2"; shift 2;;
      --require-checksum) UPD[require_checksum]=true; shift;;
      --print-json) UPD[print_json]=true; shift;;
      --token|--api-token) UPD[token]="$2"; shift 2;;
      --github) U_SRC[github]="$2"; shift 2;;
      --gitlab) U_SRC[gitlab]="$2"; shift 2;;
      --git)    U_SRC[git]="$2"; shift 2;;
      --url)    U_SRC[url]="$2"; shift 2;;
      --ftp)    U_SRC[ftp]="$2"; shift 2;;
      --sourceforge|--sf) U_SRC[sourceforge]="$2"; shift 2;;
      *) return 1;;
    esac
  done
  return 0
}

adm_update_check() {
  local cat="$1" name="$2"; shift 2 || true
  _upd_require_cmd || return $?
  _parse_common_flags "$@" || { upd_warn "flag desconhecida em check"; :; }
  _upd_prepare_paths "$cat" "$name" || return $?
  _upd_metafile_load "$cat" "$name" || return $?

  local candf; candf="$(_upd_discover_all "$cat" "$name")" || return $?
  _upd_select_best "$candf" || return $?

  # saída amigável
  adm_step "$name" "${MF[version]}" "versão upstream encontrada"
  echo "atual: ${MF[version]}"
  echo "upstream: ${CAND[version]}"
  echo "url: ${CAND[url]}"
  echo "formato: ${CAND[format]} (fonte: ${CAND[source]})"
  echo "log (descoberta): ${PATHS[discover]}"
  echo "log (seleção):    ${PATHS[select]}"

  if [[ "${UPD[print_json]}" == "true" ]]; then
    printf '{"current_version":"%s","latest_version":"%s","url":"%s","format":"%s","source":"%s"}\n' \
      "${MF[version]}" "${CAND[version]}" "${CAND[url]}" "${CAND[format]}" "${CAND[source]}"
  fi
  return 0
}

adm_update_generate() {
  local cat="$1" name="$2"; shift 2 || true
  _upd_require_cmd || return $?
  _parse_common_flags "$@" || true
  _upd_prepare_paths "$cat" "$name" || return $?
  _upd_metafile_load "$cat" "$name" || return $?

  local candf; candf="$(_upd_discover_all "$cat" "$name")" || return $?
  _upd_select_best "$candf" || return $?

  adm_step "$name" "${CAND[version]}" "baixando artefato"
  _upd_download_artifact || return $?
  adm_step "$name" "${CAND[version]}" "checando tarball"
  _upd_tar_safe "${CAND[file]}" || return $?

  adm_step "$name" "${CAND[version]}" "gerando metafile de update"
  local newmf; newmf="$(_upd_write_metafile_update "$cat" "$name")" || return $?

  adm_ok "novo metafile: $newmf"
  echo "sha256: ${CAND[sha256]}"
  echo "source: ${CAND[url]}"

  if [[ "${UPD[print_json]}" == "true" ]]; then
    printf '{"metafile_path":"%s","latest_version":"%s","url":"%s","sha256":"%s"}\n' \
      "$newmf" "${CAND[version]}" "${CAND[url]}" "${CAND[sha256]}"
  fi
  return 0
}

adm_update_adopt() {
  local name="" cat=""; U_SRC=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2;;
      --category) cat="$2"; shift 2;;
      --github) U_SRC[github]="$2"; shift 2;;
      --gitlab) U_SRC[gitlab]="$2"; shift 2;;
      --git) U_SRC[git]="$2"; shift 2;;
      --url) U_SRC[url]="$2"; shift 2;;
      --ftp) U_SRC[ftp]="$2"; shift 2;;
      --sourceforge|--sf) U_SRC[sourceforge]="$2"; shift 2;;
      *) _parse_common_flags "$1" "$2" || upd_warn "flag desconhecida: $1"; shift;;
    esac
  done
  [[ -n "$name" && -n "$cat" ]] || { upd_err "uso: adopt --name <name> --category <cat> (--url|--git|--github|--gitlab|--sourceforge)"; return 1; }
  # metafile base mínimo para comparação
  MF[name]="$name"; MF[category]="$cat"; MF[version]="0.0.0"; MF[build_type]="${MF[build_type]:-custom}"
  MF[run_deps]="${MF[run_deps]:-}"; MF[build_deps]="${MF[build_deps]:-}"; MF[opt_deps]="${MF[opt_deps]:-}"
  MF[description]="${MF[description]:-}"; MF[homepage]="${MF[homepage]:-}"; MF[maintainer]="${MF[maintainer]:-}"

  _upd_require_cmd || return $?
  _upd_prepare_paths "$cat" "$name" || return $?

  local candf; candf="$(_upd_discover_all "$cat" "$name")" || return $?
  _upd_select_best "$candf" || return $?

  adm_step "$name" "${CAND[version]}" "baixando artefato"
  _upd_download_artifact || return $?
  adm_step "$name" "${CAND[version]}" "checando tarball"
  _upd_tar_safe "${CAND[file]}" || return $?

  local newmf; newmf="$(_upd_write_metafile_update "$cat" "$name")" || return $?
  adm_ok "projeto adotado — metafile criado: $newmf"
  return 0
}

adm_update_sources() {
  local cat="$1" name="$2"; shift 2 || true
  _upd_require_cmd || return $?
  _parse_common_flags "$@" || true
  _upd_prepare_paths "$cat" "$name" || return $?
  _upd_metafile_load "$cat" "$name" || return $?

  local candf; candf="$(_upd_discover_all "$cat" "$name")" || return $?
  [[ -s "$candf" ]] || { upd_err "nenhuma fonte encontrada"; return 7; }

  if [[ "${UPD[print_json]}" == "true" ]]; then
    # transformar TSV em JSON simples
    echo -n '['
    local first=true
    while IFS=$'\t' read -r ver url fmt src pub size sumurl; do
      [[ -z "$ver" || -z "$url" ]] && continue
      $first || echo -n ','
      printf '{"version":"%s","url":"%s","format":"%s","source":"%s","published":"%s"}' \
        "$ver" "$url" "$fmt" "$src" "$pub"
      first=false
    done < "$candf"
    echo ']'
  else
    column -t -s $'\t' "$candf"
  fi
  return 0
}

###############################################################################
# CLI
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="$1"; shift || true
  case "$cmd" in
    check)    adm_update_check "$@" || exit $?;;
    generate) adm_update_generate "$@" || exit $?;;
    adopt)    adm_update_adopt "$@" || exit $?;;
    sources)  adm_update_sources "$@" || exit $?;;
    *)
      _upd_require_cmd || exit $?
      _usage
      exit 2;;
  esac
fi

ADM_UPDATE_LOADED=1
export ADM_UPDATE_LOADED
