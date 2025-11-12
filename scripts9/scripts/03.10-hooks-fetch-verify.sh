#!/usr/bin/env bash
# 03.10-hooks-fetch-verify.sh
# Hooks (pre/post-fetch), fetch paralelo e verificação de SHA256 para fontes.
# Local: /usr/src/adm/scripts/03.10-hooks-fetch-verify.sh

###############################################################################
# Modo estrito + trap de erros
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__adm_err_trap_fetch() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] hooks-fetch-verify falhou: codigo=${code} linha=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __adm_err_trap_fetch ERR

###############################################################################
# Defaults, caminhos e logging (com fallbacks)
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_CACHE_DIR="${ADM_CACHE_DIR:-${ADM_ROOT}/cache}"
ADM_CACHE_OBJS="${ADM_CACHE_OBJS:-${ADM_CACHE_DIR}/objects}"
ADM_CACHE_URLS="${ADM_CACHE_URLS:-${ADM_CACHE_DIR}/urls}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_ROOT}/state/logs}"
ADM_FETCH_JOBS="${ADM_FETCH_JOBS:-$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)}"
ADM_OFFLINE="${ADM_OFFLINE:-0}"

# Fallbacks simples de logging/utilidades (se 01.10 não foi carregado)
adm_is_cmd() { command -v "$1" >/dev/null 2>&1; }
__has_color() { [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; }
if __has_color; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
adm_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
adm_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
adm_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
adm_error(){ echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }

__ensure_dir() {
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
__ensure_dir "$ADM_TMPDIR"
__ensure_dir "$ADM_CACHE_DIR"
__ensure_dir "$ADM_CACHE_OBJS"
__ensure_dir "$ADM_CACHE_URLS"
__ensure_dir "$ADM_LOG_DIR"

tmpfile(){ mktemp "${ADM_TMPDIR}/fetch.XXXXXX"; }

# Fallbacks para SHA/Download caso 01.10 não esteja carregado
adm_sha256() {
  local f="${1:?arquivo}"
  if adm_is_cmd sha256sum; then sha256sum "$f" | awk '{print $1}'
  elif adm_is_cmd shasum; then shasum -a 256 "$f" | awk '{print $1}'
  else adm_error "sha256: nenhuma ferramenta disponível"; return 3; fi
}
adm_sha256_verify() {
  local f="${1:?arquivo}" want="${2:?sha}"
  local got; got="$(adm_sha256 "$f")" || return $?
  [[ "$got" == "$want" ]] && return 0 || { adm_error "sha256 mismatch: got=$got want=$want"; return 1; }
}
adm_retry() {
  local tries="${1:?tries}" inc_ms="${2:?inc}"; shift 2
  [[ "$1" == "--" ]] && shift || { adm_error "adm_retry: falta --"; return 2; }
  local attempt=1 delay=0 rc
  while (( attempt <= tries )); do
    if "$@"; then return 0; fi
    rc=$?; (( attempt==tries )) && return "$rc"
    delay=$((attempt*inc_ms))
    sleep "$(awk "BEGIN{printf \"%.3f\", $delay/1000}")"
    ((attempt++))
  done
}
__dl_curl() {
  local url="$1" out="$2" hdr="$3"
  local args=( -L --fail --retry 3 --retry-delay 1 --connect-timeout 10 )
  [[ -f "$hdr" ]] && args+=( -z "$out" -D "$hdr.new" ) || args+=( -D "$hdr.new" )
  [[ -f "$out" ]] && args+=( -C - )
  args+=( -o "$out" "$url" )
  curl "${args[@]}"
}
__dl_wget() {
  local url="$1" out="$2" hdr="$3"
  local args=( -O "$out" --no-verbose --tries=3 --timeout=15 )
  [[ -f "$out" ]] && args+=( -c )
  wget "${args[@]}" "$url"
  printf 'Downloaded: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%S%z")" > "$hdr.new"
}
adm_download() {
  local url="${1:?url}" out="${2:?out}"; shift 2
  local sum="" retries=3 hdr="${out}.hdr"
  while (($#)); do
    case "$1" in
      --sha256) sum="${2:-}"; shift 2 ;;
      --retries) retries="${2:-3}"; shift 2 ;;
      --etag) hdr="${2:-${out}.hdr}"; shift 2 ;;
      *) adm_error "adm_download: opção inválida $1"; return 2 ;;
    esac
  done
  __ensure_dir "$(dirname "$out")"
  if (( ADM_OFFLINE )); then
    # offline: não baixa; falha se outfile não existir
    [[ -f "$out" ]] || { adm_error "offline: artefato ausente: $out"; return 7; }
  else
    local rc=0
    adm_retry "$retries" 400 -- bash -c '
      set -Eeuo pipefail
      url="$1"; out="$2"; hdr="$3"
      if command -v curl >/dev/null 2>&1; then
        __dl_curl "$url" "$out" "$hdr"
      elif command -v wget >/dev/null 2>&1; then
        __dl_wget "$url" "$out" "$hdr"
      else
        echo "[ERR] nem curl nem wget" 1>&2; exit 9
      fi
      mv -f "$hdr.new" "$hdr" 2>/dev/null || true
    ' _ "$url" "$out" "$hdr" || rc=$?
    (( rc==0 )) || { adm_error "download falhou: $url (rc=$rc)"; return "$rc"; }
  fi
  [[ -n "$sum" ]] && adm_sha256_verify "$out" "$sum"
}

###############################################################################
# Hooks: descoberta e execução
###############################################################################
# Layout esperado dos hooks do pacote:
#   /usr/src/adm/<categoria>/<programa>/hooks/<nome-do-hook>
# Hooks globais opcionais:
#   /usr/src/adm/hooks/<nome-do-hook>
__hooks_dirs_for_pkg() {
  local cat="${ADM_META[category]:-}" prog="${ADM_META[name]:-}"
  [[ -n "$cat" && -n "$prog" ]] || return 0
  printf '%s\n' "${ADM_ROOT}/${cat}/${prog}/hooks" "${ADM_ROOT}/hooks"
}

adm_hooks_run() {
  # uso: adm_hooks_run <nome-do-hook>
  local hook="$1" d f ran=0
  [[ -n "$hook" ]] || { adm_error "hooks_run: nome do hook vazio"; return 2; }
  for d in $(__hooks_dirs_for_pkg); do
    [[ -d "$d" ]] || continue
    for f in "$d/$hook" "$d/$hook.sh"; do
      if [[ -x "$f" ]]; then
        adm_info "Executando hook: $(realpath -m "$f")"
        ( set -Eeuo pipefail; "$f" )  # subshell isolado
        ran=1
      fi
    done
  done
  (( ran )) || adm_info "Nenhum hook '${hook}' encontrado (ok)"
}

###############################################################################
# Interface com o metafile já carregado (02.10)
###############################################################################
# Espera-se ADM_META preenchido por 02.10-parse-validate-metafile.sh
__meta_arrays_from_env() {
  local -a srcs sums
  IFS=' ' read -r -a srcs <<< "${ADM_META[sources]:-}"
  IFS=' ' read -r -a sums <<< "${ADM_META[sha256sums]:-}"
  if ((${#srcs[@]}==0)); then
    adm_error "metafile: sources vazio"; return 1
  fi
  if ((${#srcs[@]}!=${#sums[@]})); then
    adm_error "metafile: sha256sums != sources"; return 1
  fi
  # exporta em variáveis globais desta função chamadora via echo
  printf '%s\0' "${srcs[@]}"; printf '::SEP::\0'; printf '%s\0' "${sums[@]}"
}
###############################################################################
# Normalização de alvos, cache e persistência de URLs
###############################################################################
__cache_obj_path() { printf '%s/%s' "$ADM_CACHE_OBJS" "$1"; }
__cache_url_path() { printf '%s/%s' "$ADM_CACHE_URLS" "$1"; }

__record_url_for_sha() {
  local sha="$1" url="$2"
  local up="$(__cache_url_path "$sha")"
  __ensure_dir "$(dirname "$up")"
  # evita duplicatas
  if [[ -f "$up" ]] && grep -qxF -- "$url" "$up" 2>/dev/null; then
    return 0
  fi
  echo "$url" >> "$up"
}

__safe_basename_from_url() {
  # Produz um nome "seguro" a partir da URL (sem query), usado apenas para tmp
  local u="$1" b
  b="${u%%\?*}"; b="${b##*/}"
  # fallback se vazio
  [[ -n "$b" ]] || b="source"
  # remove caracteres problemáticos
  b="$(sed 's/[^A-Za-z0-9._+-]/_/g' <<<"$b")"
  printf '%s' "$b"
}

__artifact_to_cache() {
  # Move artefato verificado para cache <sha>, de maneira atômica
  local sha="$1" file="$2"
  local dst="$(__cache_obj_path "$sha")"
  if [[ -f "$dst" ]]; then
    # já existe: verificar se é o mesmo; se diferente, substituir
    local have; have="$(adm_sha256 "$dst")" || true
    if [[ "$have" == "$sha" ]]; then
      return 0
    fi
  fi
  # move atômico
  mv -f -- "$file" "$dst"
}

###############################################################################
# Estratégias de obtenção por protocolo
###############################################################################
__is_local_dir() {
  local u="$1"
  [[ "$u" == /* ]] && [[ -d "$u" ]] && return 0
  [[ "$u" =~ ^file:/ ]] && [[ -d "${u#file:}" ]] && return 0
  return 1
}

__fetch_local_dir() {
  # Empacota diretório local em tar.zst temporário para garantir hash estável
  local u="$1" tmpout="$2"
  local dir="$u"
  [[ "$dir" =~ ^file:/ ]] && dir="${dir#file:}"
  [[ -d "$dir" ]] || { adm_error "diretório local inexistente: $dir"; return 2; }
  ( set -Eeuo pipefail
    cd "$dir"
    # tar com ordem estável (--sort=name), donos fixos, timestampe fixo
    tar --sort=name --owner=0 --group=0 --numeric-owner \
        --mtime='UTC 2020-01-01' -c . | zstd -q -19 -T0 -o "$tmpout"
  )
}

__is_git_url() {
  local u="$1"
  [[ "$u" =~ ^(git|ssh):// ]] || [[ "$u" =~ \.git($|\?) ]] || [[ "$u" =~ ^git@ ]]
}

__fetch_git_archive() {
  # Clona superficialmente e cria um tar do HEAD (ou ref especificada via @ref)
  local url="$1" tmpout="$2"
  local ref=""
  if [[ "$url" == *"@"* ]]; then
    ref="${url##*@}"
    url="${url%@*}"
  fi
  local tmpdir; tmpdir="$(tmpfile)"; rm -f "$tmpdir"; mkdir -p "$tmpdir"
  ( set -Eeuo pipefail
    if [[ -n "$ref" ]]; then
      git clone --depth=1 --branch "$ref" --recursive "$url" "$tmpdir/repo"
    else
      git clone --depth=1 --recursive "$url" "$tmpdir/repo"
    fi
    cd "$tmpdir/repo"
    git submodule update --init --depth 1 || true
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2020-01-01' -c . | zstd -q -19 -T0 -o "$tmpout"
  )
  rm -rf "$tmpdir"
}

__is_rsync_url() { [[ "$1" =~ ^rsync:// ]] || [[ "$1" =~ ^ssh:// ]]; }

__fetch_rsync() {
  local url="$1" tmpout="$2"
  local tmpdir; tmpdir="$(tmpfile)"; rm -f "$tmpdir"; mkdir -p "$tmpdir"
  rsync -a --delete --info=progress2 "$url" "$tmpdir/src" || { adm_error "rsync falhou: $url"; rm -rf "$tmpdir"; return 2; }
  ( set -Eeuo pipefail
    cd "$tmpdir/src"
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2020-01-01' -c . | zstd -q -19 -T0 -o "$tmpout"
  )
  rm -rf "$tmpdir"
}

__fetch_http_https() {
  local url="$1" tmpout="$2"
  adm_download "$url" "$tmpout" || return $?
}

###############################################################################
# Unidade de trabalho: baixar/verificar/cachear UM source
###############################################################################
__fetch_verify_one() {
  # args: url sha idx total
  local url="$1" sha="$2" idx="$3" total="$4"
  local dst="$(__cache_obj_path "$sha")"
  if [[ -f "$dst" ]]; then
    # já no cache — ainda registrar URL (para auditoria)
    __record_url_for_sha "$sha" "$url"
    echo "HIT $sha $dst"
    return 0
  fi
  (( ADM_OFFLINE )) && { adm_error "offline: faltando blob no cache: $sha (url: $url)"; return 9; }

  local tmp; tmp="$(tmpfile)"
  # heurística do método
  if __is_local_dir "$url"; then
    __fetch_local_dir "$url" "$tmp" || return $?
  elif __is_git_url "$url"; then
    adm_is_cmd git || { adm_error "git indisponível para $url"; return 2; }
    __fetch_git_archive "$url" "$tmp" || return $?
  elif __is_rsync_url "$url"; then
    adm_is_cmd rsync || { adm_error "rsync indisponível para $url"; return 2; }
    __fetch_rsync "$url" "$tmp" || return $?
  else
    __fetch_http_https "$url" "$tmp" || return $?
  fi

  # verifica hash
  adm_sha256_verify "$tmp" "$sha" || { rm -f "$tmp"; return 3; }

  # envia ao cache
  __artifact_to_cache "$sha" "$tmp"
  __record_url_for_sha "$sha" "$url"
  echo "MISS $sha $dst"
}

###############################################################################
# Execução paralela
###############################################################################
__parallel_supported() {
  # preferir GNU parallel; caso não haja, tentar xargs -P
  if adm_is_cmd parallel; then echo "parallel"; return 0; fi
  if xargs --help 2>/dev/null | grep -q -- '-P'; then echo "xargs"; return 0; fi
  echo "serial"; return 1
}

__run_parallel_fetch() {
  local -a urls=(); local -a shas=()
  local i
  for i in "${!FETCH_URLS[@]}"; do
    urls+=("${FETCH_URLS[$i]}"); shas+=("${FETCH_SHAS[$i]}")
  done
  local mode="$(__parallel_supported)"
  local total="${#urls[@]}"
  local rc=0

  case "$mode" in
    parallel)
      # exportar funções e variáveis necessárias para subshells do parallel
      export -f __is_local_dir __fetch_local_dir __is_git_url __fetch_git_archive \
              __is_rsync_url __fetch_rsync __fetch_http_https adm_sha256 adm_sha256_verify \
              __artifact_to_cache __record_url_for_sha __cache_obj_path adm_error adm_is_cmd adm_download \
              tmpfile __ensure_dir
      parallel -j "${ADM_FETCH_JOBS}" --halt soon,fail=1 \
        __fetch_verify_one {1} {2} {#} "${total}" ::: "${urls[@]}" ::: "${shas[@]}" || rc=$?
      ;;
    xargs)
      # Empacotar pares "url<\t>sha" e processar com xargs -P
      local list; list="$(tmpfile)"
      for i in "${!urls[@]}"; do
        printf '%s\t%s\n' "${urls[$i]}" "${shas[$i]}" >> "$list"
      done
      # shellcheck disable=SC2016
      xargs -P "${ADM_FETCH_JOBS}" -I{} bash -Eeuo pipefail -c '
        IFS=$'\''\t'\'' read -r url sha <<< "{}"
        __fetch_verify_one "$url" "$sha" 1 1
      ' < "$list" || rc=$?
      ;;
    *)
      for i in "${!urls[@]}"; do
        __fetch_verify_one "${urls[$i]}" "${shas[$i]}" "$((i+1))" "$total" || rc=$?
      done
      ;;
  esac

  return "$rc"
}
###############################################################################
# Orquestração pública: adm_fetch_and_verify
###############################################################################
adm_fetch_and_verify() {
  # Requer ADM_META carregado (name, category, sources, sha256sums)
  [[ -v ADM_META[name] && -v ADM_META[category] ]] || { adm_error "ADM_META não carregado"; return 2; }

  adm_hooks_run "pre-fetch"

  # Converter fontes e hashes para arrays
  local packed i part urls_raw sums_raw
  packed="$(__meta_arrays_from_env)" || return 3
  # split por \0 "::SEP::" \0
  local IFS= readarray -d '' -t pieces <<< "$packed"
  # pieces contém: todos os urls terminados por "" seguido de "::SEP::" e depois os sums...
  # Reconstruir corretamente:
  # Vamos reprocessar diretamente de ADM_META para simplificar:
  read -r -a FETCH_URLS <<< "${ADM_META[sources]}"
  read -r -a FETCH_SHAS <<< "${ADM_META[sha256sums]}"

  # Sanity
  ((${#FETCH_URLS[@]}>0)) || { adm_error "sources vazio"; return 4; }
  ((${#FETCH_URLS[@]}==${#FETCH_SHAS[@]})) || { adm_error "sha256sums != sources"; return 5; }

  adm_info "Iniciando fetch (${#FETCH_URLS[@]} items) | offline=${ADM_OFFLINE} | jobs=${ADM_FETCH_JOBS}"

  local rc=0
  __run_parallel_fetch || rc=$?

  if (( rc != 0 )); then
    adm_error "fetch completou com erros (rc=$rc)"
    return "$rc"
  fi

  # Verificação final: todos os objetos no cache?
  local miss=0 sha dst
  for sha in "${FETCH_SHAS[@]}"; do
    dst="$(__cache_obj_path "$sha")"
    if [[ ! -f "$dst" ]]; then
      adm_error "objeto ausente no cache após fetch: $sha"
      miss=1
    fi
  done
  (( miss==0 )) || return 6

  adm_ok "Fetch/verificação concluídos para ${ADM_META[category]}/${ADM_META[name]}@${ADM_META[version]:-?}"

  adm_hooks_run "post-fetch"
}

###############################################################################
# CLI de teste rápido (opcional)
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # Para testar, exige que 02.10 já tenha populado ADM_META ou gerar fake
  if [[ -z "${ADM_META[name]:-}" ]]; then
    adm_warn "ADM_META não definido; criando meta fake para self-test (httpbin)."
    declare -gA ADM_META=()
    ADM_META[name]="hello"
    ADM_META[category]="apps"
    ADM_META[version]="1.0.0"
    # pequeno arquivo de texto e seu sha256
    ADM_META[sources]="https://httpbin.org/bytes/16"
    # calculamos hash de um conteúdo fixo não garantido → usar outro alvo estável:
    # vamos baixar robots.txt do example.com
    ADM_META[sources]="https://example.com/"
    # Para descobrir sha: faremos um download previo num tmp
    t="$(tmpfile)"; if adm_download "https://example.com/" "$t"; then
      ADM_META[sha256sums]="$(adm_sha256 "$t")"; rm -f "$t"
    else
      # fallback: aborta self-test
      adm_error "self-test: falhou baixar conteúdo de exemplo"
      exit 90
    fi
  fi

  adm_fetch_and_verify
fi
