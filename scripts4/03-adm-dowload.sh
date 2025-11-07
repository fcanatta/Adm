#!/usr/bin/env bash
# 03-adm-download.part1.sh
# Download robusto de sources: http/https, ftp, git, rsync, file/local, diretórios
# Pré-requisitos (source antes):
#   00-adm-config.sh (ADM_CONF_LOADED)
#   01-adm-lib.sh    (ADM_LIB_LOADED)
#   02-adm-cache.sh  (ADM_CACHE_LOADED)

###############################################################################
# Guardas e pré-requisitos
###############################################################################
if [[ -n "${ADM_DL_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_DL_LOADED_PART1=1

if [[ -z "${ADM_CONF_LOADED:-}" ]]; then
  echo "ERRO: 03-adm-download requer 00-adm-config.sh carregado." >&2
  return 2 2>/dev/null || exit 2
fi
if [[ -z "${ADM_LIB_LOADED:-}" ]]; then
  echo "ERRO: 03-adm-download requer 01-adm-lib.sh carregado." >&2
  return 2 2>/dev/null || exit 2
fi
if [[ -z "${ADM_CACHE_LOADED:-}" ]]; then
  echo "ERRO: 03-adm-download requer 02-adm-cache.sh carregado." >&2
  return 2 2>/dev/null || exit 2
fi

: "${ADM_NET_RETRIES:=3}"
: "${ADM_NET_TIMEOUT:=60}"
: "${ADM_USER_AGENT:=adm/1.0 (+local)}"
: "${ADM_TLS_VERIFY:=true}"     # true/false
: "${ADM_RATE_LIMIT:=}"         # ex: 500k
: "${ADM_PROXY:=}"              # ex: http://proxy:3128

###############################################################################
# Helpers de detecção de esquema/entrada
###############################################################################
__dl_is_http()  { [[ "$1" =~ ^https?:// ]]; }
__dl_is_ftp()   { [[ "$1" =~ ^ftp:// ]]; }
__dl_is_git()   { [[ "$1" =~ ^(git(\+ssh)?|ssh):// ]] || [[ "$1" =~ \.git($|[#?/]) ]] || [[ "$1" =~ ^git\+https?:// ]]; }
__dl_is_rsync() { [[ "$1" =~ ^rsync:// ]] || [[ "$1" =~ ^[^:/]+@[^:]+: ]]; }  # user@host:path
__dl_is_file()  { [[ "$1" =~ ^file:// ]]; }
__dl_is_local_file() { [[ -f "$1" ]]; }
__dl_is_local_dir()  { [[ -d "$1" ]]; }

__dl_backend=""
adm_dl_pick_tool() {
  # Seleciona backend principal para HTTP/FTP: curl (preferido) ou wget (fallback).
  if command -v curl >/dev/null 2>&1; then
    __dl_backend="curl"
    return 0
  elif command -v wget >/dev/null 2>&1; then
    __dl_backend="wget"
    return 0
  fi
  adm_err "Nenhuma ferramenta de download encontrada (curl/wget)."
  return 2
}

###############################################################################
# Construção de comando para HTTP/FTP
###############################################################################
__dl_cmd_http() {
  # __dl_cmd_http <url> <outfile>
  local url="$1" out="$2"
  if [[ "$__dl_backend" == "curl" ]]; then
    local args=( -fL --retry "$ADM_NET_RETRIES" --retry-delay 2 --connect-timeout "$ADM_NET_TIMEOUT" --user-agent "$ADM_USER_AGENT" -o "$out" -C - "$url" )
    [[ -n "$ADM_PROXY" ]]        && args+=( --proxy "$ADM_PROXY" )
    [[ -n "$ADM_RATE_LIMIT" ]]   && args+=( --limit-rate "$ADM_RATE_LIMIT" )
    [[ "$ADM_TLS_VERIFY" == "false" ]] && args+=( --insecure )
    printf "%q " curl "${args[@]}"
  else
    local args=( --tries="$ADM_NET_RETRIES" --waitretry=2 --timeout="$ADM_NET_TIMEOUT" --user-agent="$ADM_USER_AGENT" --continue --output-document="$out" "$url" )
    [[ -n "$ADM_PROXY" ]]        && args+=( -e use_proxy=yes ) # wget lê *_proxy do ambiente
    [[ -n "$ADM_RATE_LIMIT" ]]   && args+=( --limit-rate="$ADM_RATE_LIMIT" )
    # TLS verify: wget por padrão verifica; --no-check-certificate desativa
    [[ "$ADM_TLS_VERIFY" == "false" ]] && args+=( --no-check-certificate )
    printf "%q " wget "${args[@]}"
  fi
}

###############################################################################
# Execução de um único download de URL (HTTP/FTP) com spinner e logs
###############################################################################
__dl_one_url_http() {
  # __dl_one_url_http <url> <outfile_tmp>
  local url="$1" out="$2"
  adm_with_spinner "baixando: $url" -- bash -c "$(__dl_cmd_http "$url" "$out")"
}

###############################################################################
# RSYNC
###############################################################################
__dl_one_rsync() {
  # __dl_one_rsync <rsync_url> <outfile_tmp or outdir_tmp> <mode:detect_file_or_dir>
  local url="$1" out="$2" mode="${3:-auto}"
  if ! command -v rsync >/dev/null 2>&1; then
    adm_err "rsync não encontrado"
    return 2
  fi
  # rsync pode copiar arquivos ou diretórios; vamos sincronizar para um dir tmp.
  local tmpdir; tmpdir="$(adm_mktemp_dir rsync)" || return 3
  adm_with_spinner "sincronizando via rsync: $url" -- rsync -avz --partial --timeout="$ADM_NET_TIMEOUT" "$url" "$tmpdir/"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    adm_err "rsync falhou (rc=$rc) para $url"
    return 3
  fi
  # Se copiar um arquivo, pode estar em path dentro do tmpdir; empaquetar se for diretório
  # Se out termina com .tar.*, vamos criar pacote; senão, retornar diretório.
  if [[ "$mode" == "file" && -n "$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type f -print -quit)" ]]; then
    # se destino esperado é arquivo, mover o primeiro arquivo encontrado
    local f; f="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type f | head -n1)"
    cp -f -- "$f" "$out" || { adm_err "falha ao copiar arquivo rsync"; return 3; }
    echo "$out"
  else
    # é diretório; empacotar
    local tar_tmp="${out%.*}.tar"
    ( cd "$tmpdir" && tar -cf "$tar_tmp" . ) || { adm_err "falha ao empacotar diretório rsync"; return 3; }
    if command -v zstd >/dev/null 2>&1; then
      zstd -q -T0 -19 -f "$tar_tmp" -o "$out" || { adm_err "falha ao comprimir diretório rsync"; return 3; }
      rm -f -- "$tar_tmp" || true
    else
      gzip -9 -f "$tar_tmp" || { adm_err "falha ao comprimir gzip"; return 3; }
      mv -f -- "${tar_tmp}.gz" "$out"
    fi
    echo "$out"
  fi
  return 0
}

###############################################################################
# GIT
###############################################################################
__dl_one_git() {
  # __dl_one_git <git_url[#ref]> <outfile_tmp>
  # Faz clone (shallow se possível) e empacota em tar.zst/gz -> outfile_tmp
  local url="$1" out="$2"
  if ! command -v git >/dev/null 2>&1; then
    adm_err "git não encontrado"
    return 2
  fi
  local repo="$url" ref="" tmpdir
  if [[ "$url" == *"#"* ]]; then
    repo="${url%%#*}"
    ref="${url#*#}"
  fi
  tmpdir="$(adm_mktemp_dir git)" || return 3
  local clone_args=( --depth 1 )
  [[ -n "$ref" ]] && clone_args+=( --branch "$ref" )
  adm_with_spinner "clonando git: $repo ${ref:+(ref=$ref)}" -- git clone "${clone_args[@]}" -- "$repo" "$tmpdir"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    adm_err "git clone falhou (rc=$rc) para $repo"
    return 3
  fi
  # Empacotar diretório clonado
  local tar_tmp="${out%.*}.tar"
  ( cd "$tmpdir" && tar -cf "$tar_tmp" . ) || { adm_err "falha ao empacotar repositório git"; return 3; }
  if command -v zstd >/dev/null 2>&1; then
    zstd -q -T0 -19 -f "$tar_tmp" -o "$out" || { adm_err "falha ao comprimir repositório git"; return 3; }
    rm -f -- "$tar_tmp" || true
  else
    gzip -9 -f "$tar_tmp" || { adm_err "falha ao comprimir gzip"; return 3; }
    mv -f -- "${tar_tmp}.gz" "$out"
  fi
  echo "$out"
  return 0
}

###############################################################################
# FILE / LOCAL / DIRETÓRIO
###############################################################################
__dl_one_file_url() {
  # __dl_one_file_url file:///abs/path <outfile_tmp>
  local furl="$1" out="$2"
  local path="${furl#file://}"
  if [[ ! -e "$path" ]]; then
    adm_err "file:// caminho não existe: $path"
    return 3
  fi
  if [[ -f "$path" ]]; then
    cp -f -- "$path" "$out" || { adm_err "falha copiar $path"; return 3; }
    echo "$out"; return 0
  elif [[ -d "$path" ]]; then
    local tar_tmp="${out%.*}.tar"
    ( cd "$path" && tar -cf "$tar_tmp" . ) || { adm_err "falha empacotar diretório file://"; return 3; }
    if command -v zstd >/dev/null 2>&1; then
      zstd -q -T0 -19 -f "$tar_tmp" -o "$out" || { adm_err "falha comprimir diretório file://"; return 3; }
      rm -f -- "$tar_tmp" || true
    else
      gzip -9 -f "$tar_tmp" || { adm_err "falha comprimir gzip"; return 3; }
      mv -f -- "${tar_tmp}.gz" "$out"
    fi
    echo "$out"; return 0
  fi
  adm_err "file:// caminho não suportado: $path"
  return 2
}

__dl_one_local_path() {
  # __dl_one_local_path <path> <outfile_tmp>
  local p="$1" out="$2"
  if [[ -f "$p" ]]; then
    cp -f -- "$p" "$out" || { adm_err "falha copiar $p"; return 3; }
    echo "$out"; return 0
  elif [[ -d "$p" ]]; then
    local tar_tmp="${out%.*}.tar"
    ( cd "$p" && tar -cf "$tar_tmp" . ) || { adm_err "falha empacotar diretório local"; return 3; }
    if command -v zstd >/dev/null 2>&1; then
      zstd -q -T0 -19 -f "$tar_tmp" -o "$out" || { adm_err "falha comprimir diretório local"; return 3; }
      rm -f -- "$tar_tmp" || true
    else
      gzip -9 -f "$tar_tmp" || { adm_err "falha comprimir gzip"; return 3; }
      mv -f -- "${tar_tmp}.gz" "$out"
    fi
    echo "$out"; return 0
  fi
  adm_err "caminho local inválido: $p"
  return 2
}
# 03-adm-download.part2.sh
# Continuação: laço de mirrors, finalize com cache, API pública: fetch_one/fetch_all/from_metafile
if [[ -n "${ADM_DL_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_DL_LOADED_PART2=1

###############################################################################
# Baixa de uma lista de URLs (com fallback por esquema)
###############################################################################
__dl_try_urls() {
  # __dl_try_urls <name> <ver> <idx> "<url1>" "<url2>" ...
  local name="$1" ver="$2" idx="$3"; shift 3
  local urls=( "$@" )
  local tmp; tmp="$(mktemp -p "$ADM_TMP_ROOT" "${name}-${ver}.${idx}.XXXXXX")" || { adm_err "falha mktemp"; return 3; }
  local u rc=1

  for u in "${urls[@]}"; do
    [[ -z "$u" ]] && continue
    if __dl_is_http "$u" || __dl_is_ftp "$u"; then
      # preciso de backend
      adm_dl_pick_tool || { rc=2; break; }
      if __dl_one_url_http "$u" "$tmp"; then rc=0; break; else rc=$?; fi
    elif __dl_is_git "$u"; then
      if __dl_one_git "$u" "$tmp"; then rc=0; break; else rc=$?; fi
    elif __dl_is_rsync "$u"; then
      if __dl_one_rsync "$u" "$tmp" "auto"; then rc=0; break; else rc=$?; fi
    elif __dl_is_file "$u"; then
      if __dl_one_file_url "$u" "$tmp"; then rc=0; break; else rc=$?; fi
    elif __dl_is_local_file "$u" || __dl_is_local_dir "$u"; then
      if __dl_one_local_path "$u" "$tmp"; then rc=0; break; else rc=$?; fi
    else
      adm_warn "URL/entrada não reconhecida: $u"
      rc=2
    fi
  done

  if [[ $rc -ne 0 ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
    return $rc
  fi
  echo "$tmp"
  return 0
}

###############################################################################
# Finalização: valida integridade, envia ao cache e retorna caminho final
###############################################################################
__dl_finalize() {
  # __dl_finalize <name> <ver> <idx> <tmpfile> <sha?> <url> <category> <dest_dir>
  local name="$1" ver="$2" idx="$3" tmp="$4" sha="${5:-}" url="${6:-}" cat="${7:-}" dest_dir="${8:-$ADM_CACHE_SOURCES}"
  [[ -f "$tmp" ]] || { adm_err "finalize: arquivo temporário ausente"; return 3; }

  local got
  if [[ -n "$sha" ]]; then
    if ! got="$(adm_sha256 "$tmp")"; then adm_err "falha ao calcular sha do tmp"; return 4; fi
    if [[ "$got" != "$sha" ]]; then
      adm_err "checksum divergente (got=$got expected=$sha) para $url"
      rm -f -- "$tmp" || true
      return 4
    fi
  fi

  if [[ "${ADM_CACHE_ENABLE}" == "true" ]]; then
    # put no cache (move atômico dentro do cache)
    if ! adm_cache_sources_put "$name" "$ver" "$idx" "$tmp" "$sha" "$url" "$cat"; then
      adm_err "falha ao enviar artefato ao cache"
      rm -f -- "$tmp" || true
      return 3
    fi
    # devolve caminho do cache
    local cached
    if cached="$(adm_cache_sources_has "$name" "$ver" "$idx")"; then
      echo "$cached"
      return 0
    fi
    adm_warn "put no cache feito, mas não encontrado em seguida — usando tmp local"
  fi

  # cache desativado ou falha no put — mover para destino indicado
  mkdir -p -- "$dest_dir" 2>/dev/null || { mkdir -p -- "$dest_dir" || { adm_err "não foi possível criar dest_dir: $dest_dir"; rm -f -- "$tmp" || true; return 3; }; }
  local base="$(basename -- "$tmp")"
  local final="${dest_dir%/}/$base"
  mv -f -- "$tmp" "$final" || { adm_err "falha ao mover arquivo final"; rm -f -- "$tmp" || true; return 3; }
  echo "$final"
  return 0
}

###############################################################################
# API: Baixa um único artefato (i) com mirrors
###############################################################################
adm_dl_fetch_one() {
  # adm_dl_fetch_one <name> <version> <category> <i> <url1> [url2 ...] [--sha256 <hash>] [--dest <dir>]
  local name="$1" ver="$2" cat="$3" idx="$4"; shift 4
  [[ -z "$name" || -z "$ver" || -z "$cat" || -z "$idx" ]] && { adm_err "fetch_one: parâmetros insuficientes"; return 2; }
  local urls=() sha="" dest=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sha256) sha="$2"; shift 2 ;;
      --dest)   dest="$2"; shift 2 ;;
      *) urls+=( "$1" ); shift ;;
    esac
  done
  [[ ${#urls[@]} -eq 0 ]] && { adm_err "fetch_one: nenhuma URL/entrada fornecida"; return 2; }

  # OFFLINE → somente cache
  if [[ "${ADM_OFFLINE}" == "true" ]]; then
    local cached
    if cached="$(adm_cache_sources_has "$name" "$ver" "$idx")"; then
      adm_ok "cache hit (offline) para ${name}-${ver}.${idx}"
      # replica para destino, se solicitado
      if [[ -n "$dest" ]]; then
        local out; out="$(adm_cache_sources_get "$name" "$ver" "$idx" "$dest" --hardlink)" || return $?
        echo "$out"; return 0
      else
        echo "$cached"; return 0
      fi
    fi
    adm_err "offline: artefato ausente no cache para ${name}-${ver}.${idx}"
    return 5
  fi

  # Primeiro tenta cache (mesmo online)
  local cached
  if cached="$(adm_cache_sources_has "$name" "$ver" "$idx")"; then
    adm_ok "cache hit para ${name}-${ver}.${idx}"
    if [[ -n "$dest" ]]; then
      local out; out="$(adm_cache_sources_get "$name" "$ver" "$idx" "$dest" --hardlink)" || return $?
      echo "$out"; return 0
    else
      echo "$cached"; return 0
    fi
  fi
  adm_warn "cache miss para ${name}-${ver}.${idx}"

  # Baixar/clonar/sincronizar
  local tmp
  if ! tmp="$(__dl_try_urls "$name" "$ver" "$idx" "${urls[@]}")"; then
    local rc=$?
    adm_err "todas as origens falharam para ${name}-${ver}.${idx} (rc=$rc)"
    return $rc
  fi

  # Finalizar → valida sha, envia ao cache (ou move a dest)
  local final
  if ! final="$(__dl_finalize "$name" "$ver" "$idx" "$tmp" "$sha" "${urls[0]}" "$cat" "${dest:-}")"; then
    return $?
  fi
  echo "$final"
  return 0
}

###############################################################################
# API: Baixa todos os artefatos de uma lista CSV (urls e sha256s CSV opcionais)
###############################################################################
adm_dl_fetch_all() {
  # adm_dl_fetch_all <name> <version> <category> <urls_csv> [<sha256s_csv>]
  local name="$1" ver="$2" cat="$3" urls_csv="$4" sha_csv="${5:-}"
  [[ -z "$name" || -z "$ver" || -z "$cat" || -z "$urls_csv" ]] && { adm_err "fetch_all: parâmetros insuficientes"; return 2; }

  IFS=',' read -r -a urls <<<"$urls_csv"
  local sha_list=()
  if [[ -n "$sha_csv" ]]; then
    IFS=',' read -r -a sha_list <<<"$sha_csv"
  fi

  local i=0 out path
  for u in "${urls[@]}"; do
    local sha=""; [[ -n "${sha_list[$i]:-}" ]] && sha="${sha_list[$i]}"
    # Suporte a múltiplos mirrors para um mesmo índice: separadores por espaço/pipe? Mantemos simples: um URL por índice aqui.
    if ! path="$(adm_dl_fetch_one "$name" "$ver" "$cat" "$i" "$u" --sha256 "$sha")"; then
      return $?
    fi
    printf 'i=%d path=%s\n' "$i" "$path"
    i=$((i+1))
  done
  return 0
}

###############################################################################
# API: Baixa a partir de um metafile
###############################################################################
adm_dl_from_metafile() {
  # adm_dl_from_metafile <metafile_path> [--category <cat>]
  local metafile="$1"; shift || true
  [[ -f "$metafile" ]] || { adm_err "metafile não encontrado: $metafile"; return 2; }
  local cat=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --category) cat="$2"; shift 2 ;;
      *) break ;;
    esac
  done

  # Parse KEY=VALUE (simples, sem espaços ao redor)
  local name="" version="" sources_csv="" sha_csv=""
  while IFS='=' read -r k v; do
    [[ -z "$k" ]] && continue
    [[ "$k" =~ ^# ]] && continue
    k="${k//[[:space:]]/}"
    case "$k" in
      name) name="$v" ;;
      version) version="$v" ;;
      category) [[ -z "$cat" ]] && cat="$v" ;;
      sources) sources_csv="$v" ;;
      sha256sums) sha_csv="$v" ;;
    esac
  done < <(sed 's/[[:space:]]\+$//' "$metafile")

  [[ -z "$name" || -z "$version" ]] && { adm_err "metafile inválido: name/version ausentes"; return 2; }
  [[ -z "$cat" ]] && { adm_warn "categoria não informada; usando '-'"; cat="-" ; }
  [[ -z "$sources_csv" ]] && { adm_err "metafile sem sources="; return 2; }

  adm_dl_fetch_all "$name" "$version" "$cat" "$sources_csv" "$sha_csv"
  return $?
}

###############################################################################
# Mini-CLI para teste manual (opcional)
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # Ex.: ./03-adm-download.sh one name ver cat 0 https://... --sha256 HASH
  sub="$1"; shift || true
  case "$sub" in
    one)
      adm_dl_fetch_one "$@" || exit $?
      ;;
    all)
      adm_dl_fetch_all "$@" || exit $?
      ;;
    meta)
      adm_dl_from_metafile "$@" || exit $?
      ;;
    *)
      echo "uso:" >&2
      echo "  $0 one  <name> <ver> <cat> <i> <url1> [url2 ...] [--sha256 HASH] [--dest DIR]" >&2
      echo "  $0 all  <name> <ver> <cat> <urls_csv> [sha_csv]" >&2
      echo "  $0 meta <metafile> [--category <cat>]" >&2
      exit 2
      ;;
  esac
fi

###############################################################################
# Marcar como carregado
###############################################################################
ADM_DL_LOADED=1
export ADM_DL_LOADED
