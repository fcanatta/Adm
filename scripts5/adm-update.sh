#!/usr/bin/env sh
# adm-update.sh — Descobre versões maiores no upstream, calcula SHA256 e gera metafile de update
# POSIX sh; compatível com dash/ash/busybox ash/bash.
set -u
# =========================
# 0) Config & defaults
# =========================
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_LOG_COLOR:=auto}"
: "${ADM_STAGE:=host}"
: "${ADM_PIPELINE:=update}"

BIN_DIR="$ADM_ROOT/bin"
METAFILE_DIR="$ADM_ROOT/metafile"
UPDATE_DIR="$ADM_ROOT/update"
REG_BUILD_DIR="$ADM_ROOT/registry/build"
CACHE_DIR="$ADM_ROOT/cache"
LOG_DIR="$ADM_ROOT/logs/update"

CHANNEL="stable"     # stable|lts|any
INCLUDE_DEPS=0
FORCE=0
STRICT=0
TIMEOUT=60
MAX_PAR=4
PREFER="github,gitlab,gitea,sf,pypi,crates,npm,cpan,rubygems,hackage"
VERBOSE=0

# =========================
# 1) Cores + logging fallback
# =========================
_is_tty(){ [ -t 1 ]; }
_color_on=0
_color_setup(){
  if [ "${ADM_LOG_COLOR}" = "never" ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ]; then
    _color_on=0
  elif [ "${ADM_LOG_COLOR}" = "always" ] || _is_tty; then
    _color_on=1
  else
    _color_on=0
  fi
}
_b(){ [ $_color_on -eq 1 ] && printf '\033[1m'; }
_rst(){ [ $_color_on -eq 1 ] && printf '\033[0m'; }
_c_mag(){ [ $_color_on -eq 1 ] && printf '\033[35;1m'; }  # estágio rosa
_c_yel(){ [ $_color_on -eq 1 ] && printf '\033[33;1m'; }  # path amarelo
_c_gry(){ [ $_color_on -eq 1 ] && printf '\033[38;5;244m';}

have_adm_log=0
command -v adm_log_info >/dev/null 2>&1 && have_adm_log=1

_ts(){ date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'; }
_ctx(){
  st="${ADM_STAGE:-host}"; pipe="${ADM_PIPELINE:-update}"; path="${PWD:-/}"
  if [ $_color_on -eq 1 ]; then
    printf "("; _c_mag; printf "%s" "$st"; _rst; _c_gry; printf ":%s" "$pipe"; _rst
    printf " path="; _c_yel; printf "%s" "$path"; _rst; printf ")"
  else
    printf "(%s:%s path=%s)" "$st" "$pipe" "$path"
  fi
}
say(){
  lvl="$1"; shift; msg="$*"
  if [ $have_adm_log -eq 1 ]; then
    case "$lvl" in
      INFO)  adm_log_info  "$msg";;
      WARN)  adm_log_warn  "$msg";;
      ERROR) adm_log_error "$msg";;
      STEP)  adm_log_step_start "$msg" >/dev/null;;
      OK)    adm_log_step_ok;;
      DEBUG) adm_log_debug "$msg";;
      *)     adm_log_info "$msg";;
    esac
  else
    _color_setup
    case "$lvl" in
      INFO) t="[INFO]";; WARN) t="[WARN]";; ERROR) t="[ERROR]";; STEP) t="[STEP]";; OK) t="[ OK ]";; DEBUG) t="[DEBUG]";;
      *) t="[$lvl]";;
    esac
    printf "%s [%s] %s %s\n" "$t" "$(_ts)" "$(_ctx)" "$msg"
  fi
}
die(){ say ERROR "$*"; exit 40; }

ensure_dirs(){
  for d in "$METAFILE_DIR" "$UPDATE_DIR" "$CACHE_DIR" "$LOG_DIR"; do
    [ -d "$d" ] || mkdir -p "$d" || die "não foi possível criar: $d"
  done
}

lower(){ printf "%s" "$1" | tr 'A-Z' 'a-z'; }
trim(){ printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
sha256_file(){ command -v sha256sum >/dev/null 2>&1 || die "sha256sum ausente"; sha256sum "$1" | awk '{print $1}'; }
safe_rm_rf(){
  p="$1"
  [ -n "$p" ] || { say ERROR "safe_rm_rf: caminho vazio"; return 1; }
  case "$p" in /|"") say ERROR "safe_rm_rf: caminho proibido: $p"; return 1;; esac
  rm -rf -- "$p" 2>/dev/null || { say WARN "falha ao remover $p"; return 1; }
  return 0
}

with_timeout(){
  t="$1"; shift
  if [ "$t" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    timeout "$t" "$@"
  else
    "$@"
  fi
}

# =========================
# 2) CLI
# =========================
usage(){
  cat <<'EOF'
Uso:
  adm-update.sh check <categoria> <programa> [--include-deps] [--channel stable|lts|any] [--prefer LIST] [--timeout SECS] [--verbose]
  adm-update.sh plan  <categoria> <programa> [--include-deps] [--channel ...] [--max-par N] [--strict]
  adm-update.sh run   <categoria> <programa> [--include-deps] [--channel ...] [--max-par N] [--strict] [--force]

Saída:
  Escreve o metafile em /usr/src/adm/update/<categoria>/<programa>/metafile
  E arquivos auxiliares: sources.list, sha256sums.txt, deps.new (opcional), update.log
EOF
}

parse_common_flags(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --include-deps) INCLUDE_DEPS=1;;
      --channel) shift; CHANNEL="$(lower "$1")";;
      --prefer) shift; PREFER="$1";;
      --timeout) shift; TIMEOUT="$1";;
      --max-par) shift; MAX_PAR="$1";;
      --strict) STRICT=1;;
      --force) FORCE=1;;
      --verbose) VERBOSE=1;;
      *) echo "$1";;
    esac
    shift || true
  done
}

# =========================
# 3) Leitura do metafile atual & helpers de versão
# =========================
kv_get(){
  # Lê KEY=VALUE (linhas simples) de um arquivo
  file="$1"; key="$2"
  [ -f "$file" ] || { echo ""; return; }
  awk -F'=' -v k="$key" '$1==k{print substr($0,index($0,"=")+1)}' "$file" | head -n1
}

normalize_version(){
  # remove prefixo 'v', sufixos comuns (-release, .tar.* no final)
  v="$(printf "%s" "$1" | sed 's/^v//; s/[-_]\(release\|final\)$//; s/\.tar\.[a-z0-9]\+$//')"
  # corta pre-release se canal for stable/lts
  case "$CHANNEL" in
    any) printf "%s" "$v";;
    *) printf "%s" "$v" | sed 's/\(.*[0-9]\).*/\1/';;
  esac
}

# Compara semver básico: retorna 0 se a > b
ver_gt(){
  a="$(normalize_version "$1")"; b="$(normalize_version "$2")"
  IFS=.; set -- $a; A1="${1:-0}"; A2="${2:-0}"; A3="${3:-0}"
  IFS=.; set -- $b; B1="${1:-0}"; B2="${2:-0}"; B3="${3:-0}"
  [ "$A1" -gt "$B1" ] && return 0
  [ "$A1" -lt "$B1" ] && return 1
  [ "$A2" -gt "$B2" ] && return 0
  [ "$A2" -lt "$B2" ] && return 1
  [ "$A3" -gt "$B3" ] && return 0
  return 1
}

filter_version_by_channel(){
  v="$1"
  case "$CHANNEL" in
    any) echo "$v"; return 0;;
    lts) echo "$v" | grep -Ei 'lts|long[- ]term' >/dev/null 2>&1 && echo "$v" && return 0 || return 1;;
    stable) echo "$v" | grep -Ei 'alpha|beta|rc|pre|dev|nightly' >/dev/null 2>&1 && return 1 || { echo "$v"; return 0; }
  esac
}

# =========================
# 4) Descoberta de upstream
# =========================
is_github(){ echo "$1" | grep -qE 'github\.com'; }
is_gitlab(){ echo "$1" | grep -qE 'gitlab\.com'; }
is_gitea(){  echo "$1" | grep -qE 'gitea\.'; }
is_sf(){     echo "$1" | grep -qE 'sourceforge\.net'; }
is_registry_guess(){
  echo "$1" | grep -qE 'pypi\.org|crates\.io|npmjs\.com|cpan\.|metacpan\.|rubygems\.org|hackage\.haskell\.org'
}

curl_s(){
  # curl silencioso com timeout e UA amigável
  command -v curl >/dev/null 2>&1 || { say ERROR "curl ausente"; return 1; }
  with_timeout "$TIMEOUT" curl -fsSL -A "adm-update/1.0 (+https://local)" "$@" 2>/dev/null
}

discover_from_github(){
  repo_url="$1"   # https://github.com/user/proj
  # tenta Releases API sem jq (parsing leve) ou HTML fallback
  # API sem token: https://api.github.com/repos/user/proj/releases
  api="$(echo "$repo_url" | sed 's#https://github.com/#https://api.github.com/repos/#')/releases"
  json="$(curl_s "$api")" || json=""
  if [ -n "$json" ]; then
    # extrai tag_name e tarball_url
    echo "$json" | awk '
      BEGIN{ RS="{"; FS="\n" }
      /"tag_name":/ {
        tn=""; tar=""
        for(i=1;i<=NF;i++){
          if($i ~ /"tag_name":/){ sub(/.*"tag_name":[[:space:]]*"/,"",$i); sub(/".*/,"",$i); tn=$i }
          if($i ~ /"tarball_url":/){ sub(/.*"tarball_url":[[:space:]]*"/,"",$i); sub(/".*/,"",$i); tar=$i }
        }
        if(tn!=""){ gsub(/^v/,"",tn); printf("%s %s\n", tn, tar) }
      }' 2>/dev/null
    return 0
  fi
  # Fallback: HTML releases/tags
  html="$(curl_s "$repo_url/releases")" || html=""
  [ -n "$html" ] || html="$(curl_s "$repo_url/tags")" || true
  echo "$html" | grep -Eo 'href="[^"]*/archive/refs/tags/[^"]+\.tar\.(gz|xz|zst)"' | \
    sed 's/href="//;s/"$//' | awk -v base="$repo_url" '
      {
        url=$0; ver=url; sub(/.*\/tags\/v?/,"",ver); sub(/\.tar\..*/,"",ver); gsub(/^v/,"",ver)
        if(url ~ /^http/){ print ver, url } else { printf("%s %s%s\n", ver, base, url) }
      }'
  return 0
}

discover_from_gitlab_or_gitea(){
  repo_url="$1"
  # tenta /-/releases ou /releases
  html="$(curl_s "$repo_url/-/releases")" || html=""
  [ -n "$html" ] || html="$(curl_s "$repo_url/releases")" || true
  echo "$html" | grep -Eo 'href="[^"]*/archive/[^"]+\.tar\.(gz|xz|zst)"' | \
    sed 's/href="//;s/"$//' | awk -v base="$repo_url" '
      {
        url=$0; ver=url; sub(/.*\/archive\/v?/,"",ver); sub(/\.tar\..*/,"",ver); gsub(/^v/,"",ver)
        if(url ~ /^http/){ print ver, url } else { printf("%s %s%s\n", ver, base, url) }
      }'
}

discover_from_sourceforge(){
  home="$1" # https://sourceforge.net/projects/xxx/files/
  html="$(curl_s "$home")" || html=""
  echo "$html" | grep -Eo 'https://downloads\.sourceforge\.net/[^"]+\.tar\.(gz|xz|zst)' | \
    awk '
      {
        url=$0; ver=url; sub(/^.*[-_\/]v?/,"",ver); sub(/\.tar\..*$/,"",ver); gsub(/^v/,"",ver)
        print ver, url
      }'
}

discover_from_registry(){
  # tenta registries por nome simples (não precisa URL exata)
  # $1 = registry, $2 = name
  reg="$1"; name="$2"
  case "$reg" in
    pypi)
      json="$(curl_s "https://pypi.org/pypi/$name/json")" || json=""
      [ -n "$json" ] || return 1
      ver="$(echo "$json" | awk -F'"' '/"version":/{print $4; exit}' 2>/dev/null)"
      url="$(echo "$json" | grep -Eo '"url": *"[^"]+\.tar\.(gz|xz|zst)"' | head -n1 | sed 's/.*"url":[[:space:]]*"//;s/"$//')"
      [ -n "$ver" ] && [ -n "$url" ] && printf "%s %s\n" "$ver" "$url"
      ;;
    crates)
      json="$(curl_s "https://crates.io/api/v1/crates/$name")" || json=""
      [ -n "$json" ] || return 1
      ver="$(echo "$json" | awk -F'"' '/"max_version":/{print $4; exit}' 2>/dev/null)"
      url="https://crates.io/api/v1/crates/$name/$ver/download"
      [ -n "$ver" ] && printf "%s %s\n" "$ver" "$url"
      ;;
    npm)
      json="$(curl_s "https://registry.npmjs.org/$name")" || json=""
      [ -n "$json" ] || return 1
      ver="$(echo "$json" | awk -F'"' '/"latest":/{print $4; exit}' 2>/dev/null)"
      # npm é tarball tgz via registry; deixamos URL canônica
      url="https://registry.npmjs.org/$name/-/$name-$ver.tgz"
      [ -n "$ver" ] && printf "%s %s\n" "$ver" "$url"
      ;;
    cpan)
      # usa metacpan; tarball final pode variar — melhor deixar URL do release
      json="$(curl_s "https://fastapi.metacpan.org/v1/release/$name")" || json=""
      [ -n "$json" ] || return 1
      ver="$(echo "$json" | awk -F'"' '/"version":/{print $4; exit}' 2>/dev/null)"
      url="$(echo "$json" | grep -Eo '"download_url": *"[^"]+"' | head -n1 | sed 's/.*"download_url":[[:space:]]*"//;s/"$//')"
      [ -n "$ver" ] && [ -n "$url" ] && printf "%s %s\n" "$ver" "$url"
      ;;
    rubygems)
      json="$(curl_s "https://rubygems.org/api/v1/gems/$name.json")" || json=""
      [ -n "$json" ] || return 1
      ver="$(echo "$json" | awk -F'"' '/"version":/{print $4; exit}' 2>/dev/null)"
      url="https://rubygems.org/downloads/$name-$ver.gem"
      [ -n "$ver" ] && printf "%s %s\n" "$ver" "$url"
      ;;
    hackage)
      # Hackage: https://hackage.haskell.org/package/<name>-<ver>/<name>-<ver>.tar.gz
      html="$(curl_s "https://hackage.haskell.org/package/$name")" || html=""
      ver="$(echo "$html" | grep -Eo 'data-package-version="[^"]+"' | head -n1 | sed 's/.*="//;s/"$//')"
      [ -n "$ver" ] || return 1
      url="https://hackage.haskell.org/package/$name-$ver/$name-$ver.tar.gz"
      printf "%s %s\n" "$ver" "$url"
      ;;
    *) return 1;;
  esac
}

pick_preferred_source(){
  # entrada em stdin: linhas "version url"
  # aplica filtro pelo CHANNEL e escolhe a MAIOR versão, seguindo PREFER
  tmp="$(mktemp -t adm-up-src.XXXXXX 2>/dev/null || echo "/tmp/adm-up-src.$$")"
  cat >"$tmp"
  best_ver=""; best_url=""
  # ordem preferida
  oldIFS="$IFS"; IFS=,; set -- $PREFER; IFS="$oldIFS"
  for pref in "$@"; do
    while read -r ver url || [ -n "$ver" ]; do
      [ -n "$ver" ] || continue
      case "$pref" in
        github)  echo "$url" | grep -q 'github\.com'  || continue;;
        gitlab)  echo "$url" | grep -q 'gitlab\.com'  || continue;;
        gitea)   echo "$url" | grep -q 'gitea\.'      || continue;;
        sf)      echo "$url" | grep -q 'sourceforge'  || continue;;
        pypi)    echo "$url" | grep -q 'pypi\.org'    || continue;;
        crates)  echo "$url" | grep -q 'crates\.io'   || continue;;
        npm)     echo "$url" | grep -q 'npmjs\.org\|npmjs\.com' || continue;;
        cpan)    echo "$url" | grep -q 'metacpan\|cpan' || continue;;
        rubygems) echo "$url" | grep -q 'rubygems\.org' || continue;;
        hackage) echo "$url" | grep -q 'hackage\.haskell' || continue;;
        *) :;;
      esac
      # filtra por canal
      if filter_version_by_channel "$ver" >/dev/null 2>&1; then
        if [ -z "$best_ver" ] || ver_gt "$ver" "$best_ver"; then
          best_ver="$ver"; best_url="$url"
        fi
      fi
    done <"$tmp"
  done
  rm -f "$tmp" 2>/dev/null || true
  [ -n "$best_ver" ] && printf "%s %s\n" "$best_ver" "$best_url"
}

# =========================
# 5) Descoberta principal (NAME, CATEGORY → {VERSION, SOURCES})
# =========================
discover_latest(){
  category="$1"; name="$2"
  base_meta="$METAFILE_DIR/$category/$name/metafile"
  homepage="$(kv_get "$base_meta" "HOMEPAGE")"
  sources_line="$(kv_get "$base_meta" "SOURCES")"
  current_ver="$(kv_get "$base_meta" "VERSION")"
  [ -z "$current_ver" ] && current_ver="0"

  say STEP "Descobrindo upstream para $category/$name (versão atual=$current_ver)"
  candidates=""

  # 1) Se HOMEPAGE aponta para VCS/host conhecido
  if [ -n "$homepage" ]; then
    if is_github "$homepage"; then
      out="$(discover_from_github "$homepage" 2>/dev/null || true)"; [ -n "$out" ] && candidates="${candidates}\n${out}"
    elif is_gitlab "$homepage" || is_gitea "$homepage"; then
      out="$(discover_from_gitlab_or_gitea "$homepage" 2>/dev/null || true)"; [ -n "$out" ] && candidates="${candidates}\n${out}"
    elif is_sf "$homepage"; then
      out="$(discover_from_sourceforge "$homepage" 2>/dev/null || true)"; [ -n "$out" ] && candidates="${candidates}\n${out}"
    fi
  fi

  # 2) Se SOURCES aponta para host conhecido
  if [ -n "$sources_line" ]; then
    for s in $sources_line; do
      if is_github "$s"; then
        base="$(printf "%s" "$s" | sed 's#/archive.*##; s#/releases.*##')"
        case "$base" in *github*) :;; *) base="$homepage";; esac
        out="$(discover_from_github "$base" 2>/dev/null || true)"; [ -n "$out" ] && candidates="${candidates}\n${out}"
      elif is_gitlab "$s" || is_gitea "$s"; then
        base="$(printf "%s" "$s" | sed 's#/archive.*##; s#/releases.*##')"
        [ -n "$base" ] || base="$homepage"
        out="$(discover_from_gitlab_or_gitea "$base" 2>/dev/null || true)"; [ -n "$out" ] && candidates="${candidates}\n${out}"
      elif is_sf "$s"; then
        out="$(discover_from_sourceforge "$s" 2>/dev/null || true)"; [ -n "$out" ] && candidates="${candidates}\n${out}"
      fi
    done
  fi

  # 3) Registries por nome — melhor esforço (se prefer listar esses)
  oldIFS="$IFS"; IFS=,; set -- $PREFER; IFS="$oldIFS"
  for pref in "$@"; do
    case "$pref" in
      pypi|crates|npm|cpan|rubygems|hackage)
        out="$(discover_from_registry "$pref" "$name" 2>/dev/null || true)"; [ -n "$out" ] && candidates="${candidates}\n${out}";;
    esac
  done

  # normaliza lista e seleciona melhor
  echo "$candidates" | sed '/^[[:space:]]*$/d' | pick_preferred_source
}
# =========================
# 6) Download & SHA256 (via adm-fetch.sh quando possível)
# =========================
ensure_fetch(){
  if command -v adm-fetch.sh >/dev/null 2>&1; then
    echo "ok"
  elif [ -x "$BIN_DIR/adm-fetch.sh" ]; then
    echo "ok"
  else
    echo "no"
  fi
}

download_and_sha256(){
  url="$1"; outdir="$2"
  mkdir -p "$outdir" || { say ERROR "não foi possível criar $outdir"; return 21; }
  fn="$(basename "$url" | sed 's/[?].*$//')"
  out="$outdir/$fn"
  if [ "$(ensure_fetch)" = "ok" ]; then
    # usa adm-fetch.sh para cache/parallel/sha256 check se houver metafile
    if command -v adm-fetch.sh >/dev/null 2>&1; then
      adm-fetch.sh --single "$url" --out "$outdir" --timeout "$TIMEOUT" --max-par "$MAX_PAR" >/dev/null 2>&1 || true
    else
      "$BIN_DIR/adm-fetch.sh" --single "$url" --out "$outdir" --timeout "$TIMEOUT" --max-par "$MAX_PAR" >/dev/null 2>&1 || true
    fi
  fi
  # fallback download direto se não existe ou zero
  if [ ! -s "$out" ]; then
    say INFO "baixando: $url"
    curl_s -o "$out" "$url" || { say ERROR "download falhou: $url"; rm -f "$out" 2>/dev/null; return 21; }
  fi
  [ -s "$out" ] || { say ERROR "arquivo vazio após download: $out"; return 21; }

  # valida extração básica (somente tarballs e tgz/xz/zst) — best-effort
  case "$out" in
    *.tar.*|*.tgz|*.txz|*.tzst)
      tmp="$(mktemp -d 2>/dev/null || echo "/tmp/adm-up-check-$$")"
      ok=0
      case "$out" in
        *.tar.zst|*.tzst) zstd -t "$out" >/dev/null 2>&1 && ok=1 || ok=0;;
        *.tar.xz|*.txz)  xz -t "$out"  >/dev/null 2>&1 && ok=1 || ok=0;;
        *.tar.gz|*.tgz)  gzip -t "$out" >/dev/null 2>&1 && ok=1 || ok=0;;
        *.tar) ok=1;;
      esac
      safe_rm_rf "$tmp" || true
      [ $ok -eq 1 ] || { say WARN "não foi possível validar o tarball (continua)"; }
      ;;
    *) :;;
  esac

  h="$(sha256_file "$out" 2>/dev/null || echo -)"
  [ -n "$h" ] || { say ERROR "falha ao calcular sha256: $out"; return 21; }
  printf "%s\t%s\n" "$h" "$out"
  return 0
}

# =========================
# 7) Deps: leitura atual e verificação de versão nova (opcional)
# =========================
read_current_deps(){
  category="$1"; name="$2"
  base_meta="$METAFILE_DIR/$category/$name/metafile"
  bdeps="$(kv_get "$base_meta" "BUILD_DEPS")"
  rdeps="$(kv_get "$base_meta" "RUNTIME_DEPS")"
  odeps="$(kv_get "$base_meta" "OPTIONAL_DEPS")"
  echo "BUILD_DEPS=$bdeps"
  echo "RUNTIME_DEPS=$rdeps"
  echo "OPTIONAL_DEPS=$odeps"
}

check_deps_updates(){
  category="$1"; deps_line="$2"
  # retorna linhas "dep nova_versão url"
  for dep in $deps_line; do
    # usa o mesmo processo discover, mas categoria do dep não é conhecida — supõe mesma categoria
    out="$(discover_latest "$category" "$dep" 2>/dev/null || true)"
    [ -n "$out" ] || continue
    new_ver="$(printf "%s\n" "$out" | awk '{print $1}' | head -n1)"
    new_url="$(printf "%s\n" "$out" | awk '{print $2}' | head -n1)"
    # obtém versão atual do dep (se houver metafile do dep)
    cur_meta="$METAFILE_DIR/$category/$dep/metafile"
    cur_ver="$(kv_get "$cur_meta" "VERSION")"
    [ -z "$cur_ver" ] && cur_ver="0"
    if ver_gt "$new_ver" "$cur_ver"; then
      printf "%s %s %s\n" "$dep" "$new_ver" "$new_url"
    fi
  done
}

# =========================
# 8) Emissão de arquivos (metafile/sources/sha256/deps)
# =========================
emit_metafile(){
  out_meta="$1"; name="$2"; category="$3"; homepage="$4"; version="$5"; sources_line="$6"; sha_line="$7"; bdeps="$8"; rdeps="$9"; odeps="${10}"
  {
    echo "NAME=$name"
    echo "VERSION=$version"
    echo "CATEGORY=$category"
    echo "HOMEPAGE=$homepage"
    echo "SOURCES=$sources_line"
    echo "SHA256SUMS=$sha_line"
    echo "BUILD_DEPS=$bdeps"
    echo "RUNTIME_DEPS=$rdeps"
    echo "OPTIONAL_DEPS=$odeps"
    echo "COUNT=0"
  } >"$out_meta" 2>/dev/null || return 21
}

emit_plan_files(){
  upd_dir="$1"; sources="$2"; shas="$3"; depsfile="$4"
  echo "$sources" | sed '/^[[:space:]]*$/d' >"$upd_dir/sources.list" 2>/dev/null || true
  echo "$shas" | sed '/^[[:space:]]*$/d' >"$upd_dir/sha256sums.txt" 2>/dev/null || true
  [ -n "$depsfile" ] && [ -s "$depsfile" ] && cp -a "$depsfile" "$upd_dir/deps.new" 2>/dev/null || true
}

# =========================
# 9) check / plan / run
# =========================
cmd_check(){
  category="$1"; name="$2"
  ensure_dirs
  base_meta="$METAFILE_DIR/$category/$name/metafile"
  [ -f "$base_meta" ] || { say ERROR "metafile base não encontrado: $base_meta"; exit 10; }

  current_ver="$(kv_get "$base_meta" "VERSION")"; [ -z "$current_ver" ] && current_ver="0"
  out="$(discover_latest "$category" "$name" 2>/dev/null || true)"
  [ -n "$out" ] || { say ERROR "não foi possível descobrir upstream/versão"; exit 20; }
  new_ver="$(echo "$out" | awk '{print $1}' | head -n1)"
  new_url="$(echo "$out" | awk '{print $2}' | head -n1)"

  if ver_gt "$new_ver" "$current_ver"; then
    say INFO "versão nova disponível: $current_ver → $new_ver"
    printf "%s\n" "$new_url"
  else
    say INFO "já está na última versão (ou igual): $current_ver"
    exit 20
  fi

  if [ $INCLUDE_DEPS -eq 1 ]; then
    eval "$(read_current_deps "$category" "$name")"
    deps_new="$(check_deps_updates "$category" "$RUNTIME_DEPS $BUILD_DEPS" 2>/dev/null || true)"
    [ -n "$deps_new" ] && { say INFO "deps com versão nova:"; echo "$deps_new"; } || say INFO "sem deps novas"
  fi
}

cmd_plan(){
  category="$1"; name="$2"
  ensure_dirs
  base_meta="$METAFILE_DIR/$category/$name/metafile"
  [ -f "$base_meta" ] || { say ERROR "metafile base não encontrado: $base_meta"; exit 10; }

  homepage="$(kv_get "$base_meta" "HOMEPAGE")"
  bdeps="$(kv_get "$base_meta" "BUILD_DEPS")"
  rdeps="$(kv_get "$base_meta" "RUNTIME_DEPS")"
  odeps="$(kv_get "$base_meta" "OPTIONAL_DEPS")"
  current_ver="$(kv_get "$base_meta" "VERSION")"; [ -z "$current_ver" ] && current_ver="0"

  out="$(discover_latest "$category" "$name" 2>/dev/null || true)"
  [ -n "$out" ] || { say ERROR "não foi possível descobrir upstream/versão"; exit 20; }
  new_ver="$(echo "$out" | awk '{print $1}' | head -n1)"
  new_url="$(echo "$out" | awk '{print $2}' | head -n1)"

  if ! ver_gt "$new_ver" "$current_ver"; then
    say INFO "não há versão maior (atual=$current_ver, encontrada=$new_ver)"
    exit 20
  fi

  # download e sha256
  tmpd="$(mktemp -d 2>/dev/null || echo "/tmp/adm-plan-$$")"
  pair="$(download_and_sha256 "$new_url" "$tmpd" 2>/dev/null || true)"
  [ -n "$pair" ] || { safe_rm_rf "$tmpd"; say ERROR "falha no download/sha256"; exit 21; }
  new_sha="$(echo "$pair" | awk '{print $1}')"
  file_path="$(echo "$pair" | awk '{print $2}')"
  sources_line="$new_url"
  sha_line="$new_sha"

  # deps novas (opcional)
  deps_tmp=""
  if [ $INCLUDE_DEPS -eq 1 ]; then
    deps_tmp="$(mktemp 2>/dev/null || echo "/tmp/adm-deps-$$")"
    eval "$(read_current_deps "$category" "$name")"
    check_deps_updates "$category" "$RUNTIME_DEPS $BUILD_DEPS" >"$deps_tmp" 2>/dev/null || true
  fi

  # imprimir plano
  say STEP "PLANO:"
  echo "  NAME=$name"
  echo "  VERSION: $current_ver → $new_ver"
  echo "  URL: $new_url"
  echo "  SHA256: $new_sha"
  [ -s "${deps_tmp:-/non}" ] && { echo "  DEPENDÊNCIAS NOVAS:"; sed 's/^/    /' "$deps_tmp"; } || echo "  DEPENDÊNCIAS NOVAS: (nenhuma)"

  # escrever arquivos (pré-visualização)
  upd_dir="$UPDATE_DIR/$category/$name"
  mkdir -p "$upd_dir" || { safe_rm_rf "$tmpd"; say ERROR "não foi possível criar $upd_dir"; exit 21; }
  echo "$new_url" >"$upd_dir/sources.list" 2>/dev/null || true
  printf "%s  %s\n" "$new_sha" "$(basename "$file_path")" >"$upd_dir/sha256sums.txt" 2>/dev/null || true
  [ -s "${deps_tmp:-/non}" ] && cp -a "$deps_tmp" "$upd_dir/deps.new" 2>/dev/null || true

  safe_rm_rf "$tmpd" || true
  [ -n "${deps_tmp:-}" ] && rm -f "$deps_tmp" 2>/dev/null || true

  say INFO "plan concluído — pronto para 'run'"
}

cmd_run(){
  category="$1"; name="$2"
  ensure_dirs
  base_meta="$METAFILE_DIR/$category/$name/metafile"
  [ -f "$base_meta" ] || { say ERROR "metafile base não encontrado: $base_meta"; exit 10; }

  homepage="$(kv_get "$base_meta" "HOMEPAGE")"
  bdeps="$(kv_get "$base_meta" "BUILD_DEPS")"
  rdeps="$(kv_get "$base_meta" "RUNTIME_DEPS")"
  odeps="$(kv_get "$base_meta" "OPTIONAL_DEPS")"
  current_ver="$(kv_get "$base_meta" "VERSION")"; [ -z "$current_ver" ] && current_ver="0"

  out="$(discover_latest "$category" "$name" 2>/dev/null || true)"
  [ -n "$out" ] || { say ERROR "não foi possível descobrir upstream/versão"; exit 20; }
  new_ver="$(echo "$out" | awk '{print $1}' | head -n1)"
  new_url="$(echo "$out" | awk '{print $2}' | head -n1)"

  if ! ver_gt "$new_ver" "$current_ver"; then
    [ $STRICT -eq 1 ] && { say ERROR "sem versão maior (strict)"; exit 20; }
    say WARN "sem versão maior; prosseguindo por --force? ($current_ver vs $new_ver)"
    [ $FORCE -eq 1 ] || exit 20
  fi

  tmpd="$(mktemp -d 2>/dev/null || echo "/tmp/adm-run-$$")"
  pair="$(download_and_sha256 "$new_url" "$tmpd" 2>/dev/null || true)"
  [ -n "$pair" ] || { safe_rm_rf "$tmpd"; say ERROR "falha no download/sha256"; exit 21; }
  new_sha="$(echo "$pair" | awk '{print $1}')"
  file_path="$(echo "$pair" | awk '{print $2}')"

  # deps novas (opcional)
  deps_tmp=""
  if [ $INCLUDE_DEPS -eq 1 ]; then
    deps_tmp="$(mktemp 2>/dev/null || echo "/tmp/adm-deps-$$")"
    eval "$(read_current_deps "$category" "$name")"
    check_deps_updates "$category" "$RUNTIME_DEPS $BUILD_DEPS" >"$deps_tmp" 2>/dev/null || true
  fi

  # gerar metafile final
  upd_dir="$UPDATE_DIR/$category/$name"
  mkdir -p "$upd_dir" || { safe_rm_rf "$tmpd"; say ERROR "não foi possível criar $upd_dir"; exit 21; }
  out_meta="$upd_dir/metafile"
  if [ -f "$out_meta" ] && [ $FORCE -ne 1 ]; then
    say ERROR "metafile já existe: $out_meta (use --force para sobrescrever)"
    safe_rm_rf "$tmpd" || true
    exit 10
  fi

  emit_metafile "$out_meta" "$name" "$category" "$homepage" "$new_ver" "$new_url" "$new_sha" "$bdeps" "$rdeps" "$odeps" || {
    safe_rm_rf "$tmpd"; say ERROR "falha ao escrever metafile"; exit 21; }

  # arquivos auxiliares
  printf "%s\n" "$new_url" >"$upd_dir/sources.list" 2>/dev/null || true
  printf "%s  %s\n" "$new_sha" "$(basename "$file_path")" >"$upd_dir/sha256sums.txt" 2>/dev/null || true
  [ -s "${deps_tmp:-/non}" ] && cp -a "$deps_tmp" "$upd_dir/deps.new" 2>/dev/null || true

  # log simples
  {
    echo "TIMESTAMP=$(_ts)"
    echo "OLD_VERSION=$current_ver"
    echo "NEW_VERSION=$new_ver"
    echo "URL=$new_url"
    echo "SHA256=$new_sha"
    [ -s "${deps_tmp:-/non}" ] && echo "DEPS_UPDATE=$(wc -l <"$deps_tmp" 2>/dev/null || echo 0)"
  } >"$upd_dir/update.log" 2>/dev/null || true

  safe_rm_rf "$tmpd" || true
  [ -n "${deps_tmp:-}" ] && rm -f "$deps_tmp" 2>/dev/null || true

  say INFO "metafile gerado: $out_meta"
  say OK
}
# =========================
# 10) Dispatcher
# =========================
main(){
  _color_setup
  cmd="${1:-}"; shift || true
  case "$cmd" in
    check)
      [ $# -ge 2 ] || { usage; exit 10; }
      category="$1"; name="$2"; shift 2 || true
      rem="$(parse_common_flags "$@")"; set -- $rem
      cmd_check "$category" "$name"
      ;;
    plan)
      [ $# -ge 2 ] || { usage; exit 10; }
      category="$1"; name="$2"; shift 2 || true
      rem="$(parse_common_flags "$@")"; set -- $rem
      cmd_plan "$category" "$name"
      ;;
    run)
      [ $# -ge 2 ] || { usage; exit 10; }
      category="$1"; name="$2"; shift 2 || true
      rem="$(parse_common_flags "$@")"; set -- $rem
      cmd_run "$category" "$name"
      ;;
    -h|--help|help|"")
      usage; exit 0;;
    *)
      say ERROR "subcomando desconhecido: $cmd"; usage; exit 10;;
  caseesac
}

# Corrige possível typo caso shell antigo não acuse: (garantia)
# shellcheck disable=SC2015
if [ "$(printf x)" = "x" ]; then :; fi

main "$@"
