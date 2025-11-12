#!/usr/bin/env bash
# 03.20-remote-providers-ext.sh
# Normalização de provedores remotos, mirrors, fallback, auth e fetch resiliente.
# Local: /usr/src/adm/scripts/03.20-remote-providers-ext.sh
###############################################################################
# Modo estrito + trap
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__rp_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] remote-providers-ext falhou: codigo=${code} linha=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __rp_err_trap ERR

###############################################################################
# Paths, config e logging com fallbacks
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_CACHE_DIR="${ADM_CACHE_DIR:-${ADM_ROOT}/cache}"
ADM_NET_DIR="${ADM_NET_DIR:-${ADM_STATE_DIR}/net}"
ADM_NET_RL_DIR="${ADM_NET_RL_DIR:-${ADM_NET_DIR}/ratelimit}"
ADM_HDR_CACHE_DIR="${ADM_HDR_CACHE_DIR:-${ADM_CACHE_DIR}/headers}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"

ADM_OFFLINE="${ADM_OFFLINE:-0}"
ADM_NET_TIMEOUT="${ADM_NET_TIMEOUT:-20}"       # s
ADM_NET_RETRIES="${ADM_NET_RETRIES:-3}"
ADM_NET_BACKOFF_MS="${ADM_NET_BACKOFF_MS:-400}"
ADM_USER_AGENT="${ADM_USER_AGENT:-adm-fetch/1.0 (+https://local)}"

adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }
__ensure_dir(){
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  if [[ ! -d "$d" ]]; then
    if adm_is_cmd install; then
      if [[ $EUID -ne 0 ]] && adm_is_cmd sudo; then
        sudo install -d -m "$mode" -o "$owner" -g "$group" "$d"
      else
        install -d -m "$mode" -o "$owner" -g "$group" "$d"
      fi
    else
      mkdir -p "$d"; chmod "$mode" "$d"; chown "$owner:$group" "$d" || true
    fi
  fi
}
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_CACHE_DIR"; __ensure_dir "$ADM_NET_DIR"
__ensure_dir "$ADM_NET_RL_DIR"; __ensure_dir "$ADM_HDR_CACHE_DIR"; __ensure_dir "$ADM_TMPDIR"

# Cores simples (fallback)
if [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""
fi
rp_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
rp_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
rp_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
rp_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }

tmpfile(){ mktemp "${ADM_TMPDIR}/rp.XXXXXX"; }

###############################################################################
# SHA256 + download fallbacks (se 01.10 não estiver carregado)
###############################################################################
rp_sha256(){
  local f="${1:?arquivo}"
  if adm_is_cmd sha256sum; then sha256sum "$f" | awk '{print $1}'
  elif adm_is_cmd shasum; then shasum -a 256 "$f" | awk '{print $1}'
  else rp_err "sha256: nenhuma ferramenta"; return 3; fi
}
rp_sha256_verify(){
  local f="${1:?arquivo}" want="${2:?sha}"
  local got; got="$(rp_sha256 "$f")" || return $?
  [[ "$got" == "$want" ]] && return 0 || { rp_err "sha256 mismatch: got=$got want=$want"; return 1; }
}

# Adapta adm_download caso exista; senão, implementa curl/wget com headers e proxy
rp_download(){
  local url="${1:?url}" out="${2:?outfile}"; shift 2
  local sum="" retries="$ADM_NET_RETRIES" hdr="${ADM_HDR_CACHE_DIR}/$(echo -n "$url" | rp_sha256 2>/dev/null || echo hdr)"
  while (($#)); do
    case "$1" in
      --sha256) sum="${2:-}"; shift 2 ;;
      --retries) retries="${2:-$ADM_NET_RETRIES}"; shift 2 ;;
      --etag) hdr="${2:-$hdr}"; shift 2 ;;
      *) rp_err "rp_download: opção inválida $1"; return 2 ;;
    esac
  done

  if (( ADM_OFFLINE )); then
    [[ -f "$out" ]] || { rp_err "offline: artefato ausente: $out"; return 7; }
    [[ -n "$sum" ]] && rp_sha256_verify "$out" "$sum"
    return 0
  fi

  if declare -F adm_download >/dev/null 2>&1; then
    adm_download "$url" "$out" --sha256 "${sum:-}" --retries "$retries" --etag "$hdr"
    return $?
  fi

  # fallback: curl/wget
  __ensure_dir "$(dirname "$out")"; __ensure_dir "$(dirname "$hdr")"
  local rc=0 attempt=1 delay=0
  while (( attempt <= retries )); do
    if adm_is_cmd curl; then
      local args=( -L --fail --connect-timeout "$ADM_NET_TIMEOUT" -A "$ADM_USER_AGENT" )
      [[ -f "$out" ]] && args+=( -C - )
      if [[ -f "$hdr" ]]; then args+=( -z "$out" -D "${hdr}.new" ); else args+=( -D "${hdr}.new" ); fi
      # Auth tokens, sem logar valores
      if [[ -n "${GITHUB_TOKEN:-}" && "$url" == https://github.com/* ]]; then
        args+=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
      fi
      if [[ -n "${GITLAB_TOKEN:-}" && "$url" == https://gitlab.com/* ]]; then
        args+=( -H "Authorization: Bearer ${GITLAB_TOKEN}" )
      fi
      curl "${args[@]}" -o "$out" "$url" && { mv -f "${hdr}.new" "$hdr" 2>/dev/null || true; rc=0; } || rc=$?
    elif adm_is_cmd wget; then
      local wargs=( -O "$out" --no-verbose --timeout="$ADM_NET_TIMEOUT" --tries=1 --user-agent="$ADM_USER_AGENT" )
      [[ -f "$out" ]] && wargs+=( -c )
      wget "${wargs[@]}" "$url" && { printf 'Downloaded: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%S%z")" > "${hdr}"; rc=0; } || rc=$?
    else
      rp_err "nem curl nem wget"; return 9
    fi

    if (( rc == 0 )); then
      [[ -n "$sum" ]] && rp_sha256_verify "$out" "$sum"
      return $?
    fi
    (( attempt == retries )) && break
    delay=$(( attempt * ADM_NET_BACKOFF_MS ))
    sleep "$(awk "BEGIN{printf \"%.3f\", $delay/1000}")"
    ((attempt++))
  done
  return "$rc"
}

###############################################################################
# Rate limiter simples por host (token bucket)
###############################################################################
rp_host_from_url(){
  local u="$1"
  printf '%s\n' "$u" | awk -F/ '{print $3}' | sed 's/:.*$//'
}
rp_rl_file(){ printf '%s/%s' "$ADM_NET_RL_DIR" "$(echo -n "$1" | rp_sha256 2>/dev/null || echo host)"; }
rp_rl_now_ms(){ date +%s%3N 2>/dev/null || echo "$(($(date +%s)*1000))"; }

# Config do bucket por host (capacidade N tokens, refill a cada REFILL_MS)
ADM_RL_CAPACITY="${ADM_RL_CAPACITY:-5}"
ADM_RL_REFILL_MS="${ADM_RL_REFILL_MS:-500}"

rp_rl_take(){
  # uso: rp_rl_take <url>
  local url="$1" host; host="$(rp_host_from_url "$url")"
  local f; f="$(rp_rl_file "$host")"
  local now; now="$(rp_rl_now_ms)"
  local tokens=$ADM_RL_CAPACITY last=$now
  if [[ -r "$f" ]]; then
    # formato: tokens last_ms
    read -r tokens last < "$f" || true
    [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=$ADM_RL_CAPACITY
    [[ "$last" =~ ^[0-9]+$ ]] || last=$now
    local elapsed=$(( now - last ))
    local refill=$(( elapsed / ADM_RL_REFILL_MS ))
    if (( refill > 0 )); then
      tokens=$(( tokens + refill ))
      (( tokens > ADM_RL_CAPACITY )) && tokens=$ADM_RL_CAPACITY
      last=$(( last + refill * ADM_RL_REFILL_MS ))
    fi
  fi
  if (( tokens <= 0 )); then
    # aguarda até um token
    local wait_ms=$(( ADM_RL_REFILL_MS - ( (now - last) % ADM_RL_REFILL_MS ) ))
    sleep "$(awk "BEGIN{printf \"%.3f\", $wait_ms/1000}")"
    now="$(rp_rl_now_ms)"; tokens=1; last=$now
  fi
  tokens=$(( tokens - 1 ))
  printf '%s %s\n' "$tokens" "$last" > "$f"
}

###############################################################################
# Normalização e expansão de provedores/shorthands
###############################################################################
rp_is_shorthand(){
  local u="$1"
  [[ "$u" =~ ^(gh|gl|sf):// ]]
}

rp_normalize(){
  # uso: rp_normalize <url_ou_shorthand>
  local u="${1:?}"
  if rp_is_shorthand "$u"; then
    case "$u" in
      gh://*)
        # gh://owner/repo[@ref][#path=…]
        local s="${u#gh://}" repo ref path
        repo="${s%%[@#]*}"
        [[ "$s" == *"@"* ]] && ref="${s#*@}" && ref="${ref%%#*}" || ref="HEAD"
        [[ "$s" == *"#path="* ]] && path="${s#*#path=}" || path=""
        # codeload archive URL
        if [[ "$ref" == HEAD ]]; then ref="master"; fi
        echo "https://codeload.github.com/${repo}/tar.gz/${ref}"
        return 0
        ;;
      gl://*)
        # gl://group/repo[@ref]
        local s="${u#gl://}" repo ref
        repo="${s%%@*}"
        [[ "$s" == *"@"* ]] && ref="${s#*@}" || ref="main"
        # GitLab archive
        local name; name="${repo##*/}"
        echo "https://gitlab.com/${repo}/-/archive/${ref}/${name}-${ref}.tar.gz"
        return 0
        ;;
      sf://*)
        # sf://project/path/to/file  → downloads.sourceforge.net/project/...
        local p="${u#sf://}"
        echo "https://downloads.sourceforge.net/project/${p}"
        return 0
        ;;
    esac
  fi
  echo "$u"
}

rp_github_mirrors(){
  # Entrada: gh://owner/repo[@ref] OU URL codeload
  local u="$1"
  if [[ "$u" =~ ^gh:// ]]; then u="$(rp_normalize "$u")"; fi
  # principal + espelhos alternativos (codeload é CDN; extra: fastgit)
  local base="${u}"
  local owner repo ref
  # tentar extrair owner/repo/ref de URL codeload
  if [[ "$base" =~ ^https://codeload.github.com/([^/]+)/([^/]+)/tar.gz/(.+)$ ]]; then
    owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"; ref="${BASH_REMATCH[3]}"
    printf '%s\n' "$base"
    printf 'https://github.com/%s/%s/archive/%s.tar.gz\n' "$owner" "$repo" "$ref"
    printf 'https://download.fastgit.org/%s/%s/archive/%s.tar.gz\n' "$owner" "$repo" "$ref"
  else
    printf '%s\n' "$base"
  fi
}

rp_gitlab_mirrors(){
  local u="$1"
  if [[ "$u" =~ ^gl:// ]]; then u="$(rp_normalize "$u")"; fi
  printf '%s\n' "$u"
}

rp_sf_mirrors(){
  local u="$1"
  if [[ "$u" =~ ^sf:// ]]; then u="$(rp_normalize "$u")"; fi
  # downloads.sourceforge.net já resolve mirror; adicionar fallback direto
  printf '%s\n' "$u"
  # tentar hostname prdownloads (alguns casos)
  if [[ "$u" =~ ^https://downloads.sourceforge.net/project/(.+)$ ]]; then
    printf 'https://prdownloads.sourceforge.net/%s\n' "${BASH_REMATCH[1]}"
  fi
}

rp_candidates(){
  # uso: rp_candidates <url_ou_shorthand> → imprime lista (um por linha)
  local u="${1:?}"; local canon; canon="$(rp_normalize "$u")"
  case "$u" in
    gh://*|https://codeload.github.com/*|https://github.com/*/archive/*)
      rp_github_mirrors "$u"
      ;;
    gl://*|https://gitlab.com/*/-/archive/*)
      rp_gitlab_mirrors "$u"
      ;;
    sf://*|https://downloads.sourceforge.net/*|https://prdownloads.sourceforge.net/*)
      rp_sf_mirrors "$u"
      ;;
    *) printf '%s\n' "$canon" ;;
  esac
}

###############################################################################
# Auxiliar: escolher nome seguro para outfile temporário
###############################################################################
rp_safe_basename(){
  local u="$1" b
  b="${u%%\?*}"; b="${b##*/}"
  [[ -n "$b" ]] || b="source"
  sed 's/[^A-Za-z0-9._+-]/_/g' <<<"$b"
}
###############################################################################
# Fetch com mirrors, auth e rate-limit
###############################################################################
rp_fetch(){
  # uso: rp_fetch <url_ou_shorthand> <outfile> [--sha256 SUM]
  local input="${1:?}" out="${2:?}"; shift 2
  local want_sha="" ; while (($#)); do
    case "$1" in
      --sha256) want_sha="${2:-}"; shift 2 ;;
      *) rp_err "rp_fetch: opção inválida $1"; return 2 ;;
    esac
  done

  if (( ADM_OFFLINE )); then
    # offline: requer já existir
    [[ -f "$out" ]] || { rp_err "offline: outfile não existe: $out"; return 7; }
    [[ -n "$want_sha" ]] && rp_sha256_verify "$out" "$want_sha"
    rp_ok "offline: usando artefato existente: $out"
    return 0
  fi

  local cands; mapfile -t cands < <(rp_candidates "$input")
  ((${#cands[@]}>0)) || { rp_err "nenhum candidato gerado para '$input'"; return 8; }

  local tmp; tmp="$(tmpfile)"; local rc=1
  for u in "${cands[@]}"; do
    rp_info "tentando: $u"
    rp_rl_take "$u"      # rate-limit por host

    # baixa para tmp
    if rp_download "$u" "$tmp" --sha256 "${want_sha:-}"; then
      mv -f "$tmp" "$out"
      rp_ok "baixado: $u -> $out"
      return 0
    else
      rc=$?
      rp_warn "falhou: $u (rc=$rc); tentando próximo candidato..."
      rm -f "$tmp" 2>/dev/null || true
    fi
  done
  rp_err "todos os candidatos falharam para '$input'"
  return "$rc"
}

###############################################################################
# Fallbacks VCS (git/rsync/ssh) quando URL direta não é arquivo
###############################################################################
rp_fetch_vcs_or_dir(){
  # uso: rp_fetch_vcs_or_dir <url|dir> <outfile> [--sha256 SUM]
  local src="${1:?}" out="${2:?}"; shift 2
  local want_sha=""; [[ "$1" == "--sha256" ]] && { want_sha="${2:-}"; shift 2; }

  local tmp; tmp="$(tmpfile)"; rm -f "$tmp"
  if [[ "$src" == /* || "$src" =~ ^file:/ ]]; then
    # diretório local → pacote determinístico
    local dir="$src"; [[ "$dir" =~ ^file:/ ]] && dir="${dir#file:}"
    [[ -d "$dir" ]] || { rp_err "diretório não existe: $dir"; return 2; }
    ( set -Eeuo pipefail
      cd "$dir"
      tar --sort=name --owner=0 --group=0 --numeric-owner \
          --mtime='UTC 2020-01-01' -c . | zstd -q -19 -T0 -o "$out"
    )
    [[ -n "$want_sha" ]] && rp_sha256_verify "$out" "$want_sha"
    rp_ok "empacotado diretório: $dir -> $out"
    return 0
  fi

  if [[ "$src" =~ ^(git|ssh):// || "$src" =~ ^git@ || "$src" =~ \.git($|\?) ]]; then
    adm_is_cmd git || { rp_err "git indisponível"; return 2; }
    local ref=""; [[ "$src" == *"@"* ]] && ref="${src##*@}" && src="${src%@*}"
    local tdir; tdir="$(tmpfile)"; rm -f "$tdir"; mkdir -p "$tdir"
    ( set -Eeuo pipefail
      if [[ -n "$ref" ]]; then
        git clone --depth=1 --branch "$ref" --recursive "$src" "$tdir/repo"
      else
        git clone --depth=1 --recursive "$src" "$tdir/repo"
      fi
      cd "$tdir/repo" || exit 3
      git submodule update --init --depth 1 || true
      tar --sort=name --owner=0 --group=0 --numeric-owner \
          --mtime='UTC 2020-01-01' -c . | zstd -q -19 -T0 -o "$out"
    )
    rm -rf "$tdir"
    [[ -n "$want_sha" ]] && rp_sha256_verify "$out" "$want_sha"
    rp_ok "empacotado git: $src -> $out"
    return 0
  fi

  if [[ "$src" =~ ^(rsync|ssh):// ]]; then
    adm_is_cmd rsync || { rp_err "rsync indisponível"; return 2; }
    local tdir; tdir="$(tmpfile)"; rm -f "$tdir"; mkdir -p "$tdir"
    rsync -a --delete --info=progress2 "$src" "$tdir/src" || { rp_err "rsync falhou"; rm -rf "$tdir"; return 3; }
    ( set -Eeuo pipefail
      cd "$tdir/src"
      tar --sort=name --owner=0 --group=0 --numeric-owner \
          --mtime='UTC 2020-01-01' -c . | zstd -q -19 -T0 -o "$out"
    )
    rm -rf "$tdir"
    [[ -n "$want_sha" ]] && rp_sha256_verify "$out" "$want_sha"
    rp_ok "empacotado rsync: $src -> $out"
    return 0
  fi

  # Caso contrário, tente fetch normal (http/https/etc.)
  rp_fetch "$src" "$out" ${want_sha:+--sha256 "$want_sha"}
}

###############################################################################
# API pública deste módulo
###############################################################################
rp_init(){
  __ensure_dir "$ADM_NET_RL_DIR"
  __ensure_dir "$ADM_HDR_CACHE_DIR"
  : "${ADM_OFFLINE:=0}"
  : "${ADM_NET_TIMEOUT:=20}"
  : "${ADM_NET_RETRIES:=3}"
  : "${ADM_NET_BACKOFF_MS:=400}"
  : "${ADM_USER_AGENT:=adm-fetch/1.0 (+https://local)}"
  rp_ok "remote-providers pronto (offline=${ADM_OFFLINE}, timeout=${ADM_NET_TIMEOUT}s, retries=${ADM_NET_RETRIES})"
}

###############################################################################
# Self-test básico quando chamado diretamente
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  rp_init
  # Teste só normalização (não baixa nada em offline):
  rp_info "canon GH: $(rp_normalize 'gh://torvalds/linux@v6.10')"
  rp_info "canon GL: $(rp_normalize 'gl://gitlab-org/gitlab@v17.4.1')"
  rp_info "canon SF: $(rp_normalize 'sf://nmap/nmap/nmap-7.95.tar.bz2')"

  if (( ADM_OFFLINE == 0 )); then
    t="$(tmpfile)"
    # Pequeno alvo estável: robots.txt do example.com
    if rp_fetch "https://example.com/" "$t"; then
      rp_ok "fetch ok ($t, $(stat -c%s "$t" 2>/dev/null || wc -c <"$t") bytes)"
      rm -f "$t"
    else
      rp_warn "fetch de teste falhou (ok em ambientes sem rede restrita)"
    fi
  else
    rp_info "offline=1: pulando fetch real."
  fi
fi
