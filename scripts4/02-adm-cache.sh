#!/usr/bin/env bash
# 02-adm-cache.sh
# Camada de cache (sources e tarballs) do ADM.
# - Necessita: 00-adm-config.sh (ADM_CONF_LOADED) e 01-adm-lib.sh (ADM_LIB_LOADED)
# - Sem erros silenciosos: toda falha retorna ≠0 e loga via adm_err/adm_warn.

###############################################################################
# Guardas e pré-requisitos
###############################################################################
if [[ -n "${ADM_CACHE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

if [[ -z "${ADM_CONF_LOADED:-}" ]]; then
  echo "ERRO: 02-adm-cache requer 00-adm-config.sh carregado antes." >&2
  return 2 2>/dev/null || exit 2
fi
if [[ -z "${ADM_LIB_LOADED:-}" ]]; then
  echo "ERRO: 02-adm-cache requer 01-adm-lib.sh carregado antes." >&2
  return 2 2>/dev/null || exit 2
fi

###############################################################################
# Utilitários internos
###############################################################################
__cache_err()  { adm_err "$*"; }
__cache_warn() { adm_warn "$*"; }
__cache_info() { adm_log INFO "$ADM_LOG_PKG" cache "$*"; }

__ensure_dir() {
  local d="$1"
  [[ -z "$d" ]] && { __cache_err "diretório vazio"; return 2; }
  mkdir -p -- "$d" 2>/dev/null || { mkdir -p -- "$d" || { __cache_err "falha ao criar diretório: $d"; return 3; }; }
  chmod 0755 "$d" 2>/dev/null || true
}

__safe_basename() {
  local p="${1:-}"
  basename -- "$p"
}

__file_size() {
  local f="$1"
  [[ -f "$f" ]] || { echo 0; return 1; }
  stat -c '%s' -- "$f" 2>/dev/null || wc -c < "$f" 2>/dev/null
}

__now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Caminhos para sources e tarballs
__src_base() {
  local name="$1" ver="$2" idx="$3"
  name="$(adm_sanitize_name "$name")"
  ver="$(adm_sanitize_name "$ver")"
  idx="$(adm_sanitize_name "$idx")"
  printf "%s/%s-%s.%s" "$ADM_CACHE_SOURCES" "$name" "$ver" "$idx"
}
__src_file_guess_ext() {
  # se existir extensão original (tar.xz/zip) pelo nome fornecido, preserva
  local src_path="$1" base ext
  base="$(__safe_basename "$src_path")"
  case "$base" in
    *.tar.*|*.tgz|*.zip|*.xz|*.gz|*.bz2|*.zst|*.7z) ext="${base##*.}"; echo ".$ext"; return 0 ;;
    *) echo ".src"; return 0 ;;
  esac
}
__src_paths() {
  # stdout: arquivo e index
  local name="$1" ver="$2" idx="$3" ext="${4:-}"
  local base="$(__src_base "$name" "$ver" "$idx")"
  local f="${base}${ext:-.src}"; local i="${f}.index"
  printf "%s %s" "$f" "$i"
}

__bin_paths() {
  local name="$1" ver="$2" profile="$3"
  name="$(adm_sanitize_name "$name")"
  ver="$(adm_sanitize_name "$ver")"
  profile="$(adm_sanitize_name "$profile")"
  local f="${ADM_CACHE_TARBALLS}/${name}-${ver}-${profile}.tar.zst"
  local i="${f}.index"
  printf "%s %s" "$f" "$i"
}

__write_index() {
  local idx="$1"; shift
  local lines=( "$@" )
  local dir; dir="$(dirname -- "$idx")"
  __ensure_dir "$dir" || return 3
  local tmp="${idx}.tmp.$$"
  {
    for l in "${lines[@]}"; do printf "%s\n" "$l"; done
  } > "$tmp" 2>/dev/null || { __cache_err "falha ao escrever índice temporário"; rm -f -- "$tmp" || true; return 3; }
  mv -f -- "$tmp" "$idx" 2>/dev/null || { __cache_err "falha ao mover índice para destino"; rm -f -- "$tmp" || true; return 3; }
  chmod 0644 "$idx" 2>/dev/null || true
}

__read_index() {
  local idx="$1"
  [[ -f "$idx" ]] || return 1
  cat -- "$idx"
}

__calc_sha() {
  local f="$1"
  adm_sha256 "$f" # delega para lib (com fallback)
}

__same_fs() {
  # retorna 0 se origem e destino estão no mesmo filesystem
  local src="$1" dst_dir="$2"
  local s_dev d_dev
  s_dev="$(df -P "$src" 2>/dev/null | awk 'NR==2{print $1}')" || return 1
  d_dev="$(df -P "$dst_dir" 2>/dev/null | awk 'NR==2{print $1}')" || return 1
  [[ "$s_dev" == "$d_dev" ]]
}

__atomic_place() {
  # __atomic_place <src_temp> <final_dest_dir> <final_basename>
  local src="$1" destdir="$2" base="$3"
  __ensure_dir "$destdir" || return 3
  local dest="${destdir%/}/$base"
  # garantir operação atômica: criar tmp no mesmo dir do destino
  local tmp="${dest}.tmp.$$"
  if ! mv -f -- "$src" "$tmp" 2>/dev/null; then
    # fallback: copiar para tmp no destino
    if ! cp -f -- "$src" "$tmp" 2>/dev/null; then
      __cache_err "falha ao copiar temporário para $destdir"
      return 3
    fi
    rm -f -- "$src" || true
  fi
  mv -f -- "$tmp" "$dest" 2>/dev/null || { __cache_err "falha ao mover tmp para destino final: $dest"; rm -f -- "$tmp" || true; return 3; }
  echo "$dest"
}

__copy_or_link() {
  # __copy_or_link <cache_file> <dest_dir> <policy:hardlink|copy>
  local src="$1" destdir="$2" policy="$3"
  __ensure_dir "$destdir" || return 3
  local base="$(__safe_basename "$src")"
  local dest="${destdir%/}/$base"
  case "$policy" in
    hardlink)
      if __same_fs "$src" "$destdir"; then
        ln -f "$src" "$dest" 2>/dev/null || cp -f -- "$src" "$dest" || { __cache_err "falha ao replicar $src"; return 3; }
      else
        cp -f -- "$src" "$dest" || { __cache_err "falha ao copiar $src"; return 3; }
      fi
      ;;
    copy|*)
      cp -f -- "$src" "$dest" || { __cache_err "falha ao copiar $src"; return 3; }
      ;;
  esac
  chmod 0644 "$dest" 2>/dev/null || true
  echo "$dest"
}

__parse_kv() {
  # __parse_kv <file> <key>
  local f="$1" k="$2"
  [[ -f "$f" ]] || return 1
  awk -F '=' -v key="$k" '($1==key){$1=""; sub(/^=/,"",$0); print $0; found=1} END{exit found?0:1}' "$f"
}

###############################################################################
# API - Consulta / Info
###############################################################################
adm_cache_sources_info() {
  local name="$1" ver="$2" idx="${3:-0}"
  [[ -z "$name" || -z "$ver" ]] && { __cache_err "sources_info: parâmetros ausentes"; return 2; }
  read -r f i < <(__src_paths "$name" "$ver" "$idx" ".src") || true
  if [[ -f "$i" ]]; then __read_index "$i"; return 0; fi
  # tenta qualquer extensão conhecida
  for ext in .src .tar.zst .tar.xz .tar.gz .tgz .zip .xz .gz .bz2 .7z; do
    read -r f i < <(__src_paths "$name" "$ver" "$idx" "$ext")
    [[ -f "$i" ]] && { __read_index "$i"; return 0; }
  done
  return 1
}

adm_cache_tarball_info() {
  local name="$1" ver="$2" profile="$3"
  [[ -z "$name" || -z "$ver" || -z "$profile" ]] && { __cache_err "tarball_info: parâmetros ausentes"; return 2; }
  read -r f i < <(__bin_paths "$name" "$ver" "$profile")
  [[ -f "$i" ]] && { __read_index "$i"; return 0; }
  return 1
}

adm_cache_sources_has() {
  local name="$1" ver="$2" idx="${3:-0}"
  [[ -z "$name" || -z "$ver" ]] && { __cache_err "sources_has: parâmetros ausentes"; return 2; }
  # tenta várias extensões
  local f i hash exp
  for ext in .src .tar.zst .tar.xz .tar.gz .tgz .zip .xz .gz .bz2 .7z; do
    read -r f i < <(__src_paths "$name" "$ver" "$idx" "$ext")
    [[ -f "$f" ]] || continue
    # se há index com sha, valida
    if [[ -f "$i" ]]; then
      exp="$(__parse_kv "$i" "sha256" || true)"
      if [[ -n "$exp" ]]; then
        if ! hash="$(__calc_sha "$f")"; then return 4; fi
        if [[ "$hash" != "$exp" ]]; then
          __cache_warn "hash divergente para $f (cache inválido), removendo index"
          rm -f -- "$i" || true
          return 1
        fi
      fi
    fi
    echo "$f"
    return 0
  done
  return 1
}

adm_cache_tarball_has() {
  local name="$1" ver="$2" profile="$3"
  [[ -z "$name" || -z "$ver" || -z "$profile" ]] && { __cache_err "tarball_has: parâmetros ausentes"; return 2; }
  read -r f i < <(__bin_paths "$name" "$ver" "$profile")
  [[ -f "$f" ]] || return 1
  if [[ -f "$i" ]]; then
    local exp hash
    exp="$(__parse_kv "$i" "sha256" || true)"
    if [[ -n "$exp" ]]; then
      if ! hash="$(__calc_sha "$f")"; then return 4; fi
      [[ "$hash" == "$exp" ]] || { __cache_warn "hash divergente $f (cache inválido), removendo index"; rm -f -- "$i" || true; return 1; }
    fi
  fi
  echo "$f"
  return 0
}

###############################################################################
# API - PUT (escrita atômica)
###############################################################################
adm_cache_sources_put() {
  # adm_cache_sources_put <name> <version> <i> <src_path> [<sha256>] [<url>] [<category>]
  local name="$1" ver="$2" idx="$3" src="$4" sha="${5:-}" url="${6:-}" cat="${7:-}"
  [[ -z "$name" || -z "$ver" || -z "$idx" || -z "$src" ]] && { __cache_err "sources_put: parâmetros insuficientes"; return 2; }
  [[ -f "$src" ]] || { __cache_err "sources_put: arquivo não existe: $src"; return 3; }
  if [[ "${ADM_CACHE_ENABLE}" != "true" ]]; then
    __cache_warn "cache desativado (ADM_CACHE_ENABLE=false) — ignorando put"
    return 0
  fi

  local lock="cache-src-${name}-${ver}-${idx}"
  adm_with_lock "$lock" -- bash -c '
    set -euo pipefail
    name="$1"; ver="$2"; idx="$3"; src="$4"; sha="$5"; url="$6"; cat="$7"
    ext="$(__src_file_guess_ext "$src")"
    read -r dst idxf < <(__src_paths "$name" "$ver" "$idx" "$ext")
    # verificação/geração de hash
    got=""
    if [[ -n "$sha" ]]; then
      if ! got="$(__calc_sha "$src")"; then exit 4; fi
      if [[ "$got" != "$sha" ]]; then
        __cache_err "sources_put: checksum divergente (got=$got expected=$sha)"
        exit 4
      fi
    else
      if ! got="$(__calc_sha "$src")"; then exit 4; fi
    fi
    # colocar de forma atômica
    dst_final="$(__atomic_place "$src" "$(dirname -- "$dst")" "$(__safe_basename "$dst")")" || exit 3
    size="$(__file_size "$dst_final")"
    __write_index "$idxf" \
      "key=SRC:${name}:${ver}:${idx}" \
      "sha256=${got}" \
      "size=${size}" \
      "created_at=$(__now_iso)" \
      "source_url=${url}" \
      "category=${cat}" \
      "profile=-" || exit 3
  ' bash "$name" "$ver" "$idx" "$src" "$sha" "$url" "$cat"
}

adm_cache_tarball_put() {
  # adm_cache_tarball_put <name> <version> <profile> <tar_path> [<sha256>] [<category>] [<files_count>]
  local name="$1" ver="$2" profile="$3" tar="$4" sha="${5:-}" cat="${6:-}" files="${7:-}"
  [[ -z "$name" || -z "$ver" || -z "$profile" || -z "$tar" ]] && { __cache_err "tarball_put: parâmetros insuficientes"; return 2; }
  [[ -f "$tar" ]] || { __cache_err "tarball_put: arquivo não existe: $tar"; return 3; }
  if [[ "${ADM_CACHE_ENABLE}" != "true" ]]; then
    __cache_warn "cache desativado (ADM_CACHE_ENABLE=false) — ignorando put"
    return 0
  fi

  local lock="cache-bin-${name}-${ver}-${profile}"
  adm_with_lock "$lock" -- bash -c '
    set -euo pipefail
    name="$1"; ver="$2"; profile="$3"; tar="$4"; sha="$5"; cat="$6"; files="$7"
    read -r dst idxf < <(__bin_paths "$name" "$ver" "$profile")
    got=""
    if [[ -n "$sha" ]]; then
      if ! got="$(__calc_sha "$tar")"; then exit 4; fi
      if [[ "$got" != "$sha" ]]; then
        __cache_err "tarball_put: checksum divergente (got=$got expected=$sha)"
        exit 4
      fi
    else
      if ! got="$(__calc_sha "$tar")"; then exit 4; fi
    fi
    dst_final="$(__atomic_place "$tar" "$(dirname -- "$dst")" "$(__safe_basename "$dst")")" || exit 3
    size="$(__file_size "$dst_final")"
    __write_index "$idxf" \
      "key=BIN:${name}:${ver}:${profile}" \
      "sha256=${got}" \
      "size=${size}" \
      "created_at=$(__now_iso)" \
      "category=${cat}" \
      "files_count=${files}" || exit 3
  ' bash "$name" "$ver" "$profile" "$tar" "$sha" "$cat" "$files"
}

###############################################################################
# API - GET (replicar do cache)
###############################################################################
adm_cache_sources_get() {
  # adm_cache_sources_get <name> <version> <i> <dest_dir> [--hardlink|--copy]
  local name="$1" ver="$2" idx="$3" dest="$4" mode="${5:---hardlink}"
  [[ -z "$name" || -z "$ver" || -z "$idx" || -z "$dest" ]] && { __cache_err "sources_get: parâmetros insuficientes"; return 2; }
  local f
  if ! f="$(adm_cache_sources_has "$name" "$ver" "$idx")"; then
    [[ $? -eq 1 ]] && { __cache_warn "sources_get: não encontrado em cache"; return 1; }
    return 4
  fi
  local pol="copy"
  case "$mode" in
    --hardlink) pol="hardlink";;
    --copy|*) pol="copy";;
  esac
  __copy_or_link "$f" "$dest" "$pol" || return $?
}

adm_cache_tarball_get() {
  # adm_cache_tarball_get <name> <version> <profile> <dest_dir> [--hardlink|--copy]
  local name="$1" ver="$2" profile="$3" dest="$4" mode="${5:---hardlink}"
  [[ -z "$name" || -z "$ver" || -z "$profile" || -z "$dest" ]] && { __cache_err "tarball_get: parâmetros insuficientes"; return 2; }
  local f
  if ! f="$(adm_cache_tarball_has "$name" "$ver" "$profile")"; then
    [[ $? -eq 1 ]] && { __cache_warn "tarball_get: não encontrado em cache"; return 1; }
    return 4
  fi
  local pol="copy"
  case "$mode" in
    --hardlink) pol="hardlink";;
    --copy|*) pol="copy";;
  esac
  __copy_or_link "$f" "$dest" "$pol" || return $?
}

###############################################################################
# API - DROP (remoção)
###############################################################################
adm_cache_sources_drop() {
  local name="$1" ver="$2" idx="$3"
  [[ -z "$name" || -z "$ver" || -z "$idx" ]] && { __cache_err "sources_drop: parâmetros insuficientes"; return 2; }
  local removed=0
  for ext in .src .tar.zst .tar.xz .tar.gz .tgz .zip .xz .gz .bz2 .7z; do
    read -r f i < <(__src_paths "$name" "$ver" "$idx" "$ext")
    [[ -f "$f" ]] && { rm -f -- "$f" || { __cache_err "falha ao remover $f"; return 3; }; removed=1; }
    [[ -f "$i" ]] && { rm -f -- "$i" || { __cache_err "falha ao remover $i"; return 3; }; removed=1; }
  done
  [[ $removed -eq 1 ]] || { __cache_warn "sources_drop: nada a remover"; return 1; }
  adm_ok "sources drop: ${name}-${ver}.${idx}"
  return 0
}

adm_cache_tarball_drop() {
  local name="$1" ver="$2" profile="$3"
  [[ -z "$name" || -z "$ver" || -z "$profile" ]] && { __cache_err "tarball_drop: parâmetros insuficientes"; return 2; }
  read -r f i < <(__bin_paths "$name" "$ver" "$profile")
  local removed=0
  [[ -f "$f" ]] && { rm -f -- "$f" || { __cache_err "falha ao remover $f"; return 3; }; removed=1; }
  [[ -f "$i" ]] && { rm -f -- "$i" || { __cache_err "falha ao remover $i"; return 3; }; removed=1; }
  [[ $removed -eq 1 ]] || { __cache_warn "tarball_drop: nada a remover"; return 1; }
  adm_ok "tarball drop: ${name}-${ver}-${profile}"
  return 0
}

###############################################################################
# API - Verify/Reindex
###############################################################################
adm_cache_verify_sources() {
  local name="$1" ver="$2" idx="$3"
  [[ -z "$name" || -z "$ver" || -z "$idx" ]] && { __cache_err "verify_sources: parâmetros insuficientes"; return 2; }
  local f i exp got size
  local found=1
  for ext in .src .tar.zst .tar.xz .tar.gz .tgz .zip .xz .gz .bz2 .7z; do
    read -r f i < <(__src_paths "$name" "$ver" "$idx" "$ext")
    [[ -f "$f" ]] || continue
    found=0
    size="$(__file_size "$f")"
    if [[ -f "$i" ]]; then
      exp="$(__parse_kv "$i" "sha256" || true)"
      if ! got="$(__calc_sha "$f")"; then return 4; fi
      if [[ -n "$exp" && "$got" != "$exp" ]]; then
        __cache_err "verify_sources: checksum divergente ($f)"
        return 4
      fi
      # reescreve index com size atualizado
      __write_index "$i" \
        "key=SRC:${name}:${ver}:${idx}" \
        "sha256=${got}" \
        "size=${size}" \
        "created_at=$(__now_iso)" \
        "source_url=$(__parse_kv "$i" "source_url" || true)" \
        "category=$(__parse_kv "$i" "category" || true)" \
        "profile=-" || return 3
      adm_ok "verify_sources: OK ($f)"
      return 0
    else
      # criar index novo
      if ! got="$(__calc_sha "$f")"; then return 4; fi
      __write_index "$i" \
        "key=SRC:${name}:${ver}:${idx}" \
        "sha256=${got}" \
        "size=${size}" \
        "created_at=$(__now_iso)" \
        "source_url=" \
        "category=" \
        "profile=-" || return 3
      adm_ok "verify_sources: index criado ($f)"
      return 0
    fi
  done
  return $found
}

adm_cache_verify_tarball() {
  local name="$1" ver="$2" profile="$3"
  [[ -z "$name" || -z "$ver" || -z "$profile" ]] && { __cache_err "verify_tarball: parâmetros insuficientes"; return 2; }
  read -r f i < <(__bin_paths "$name" "$ver" "$profile")
  [[ -f "$f" ]] || { __cache_warn "verify_tarball: arquivo ausente"; return 1; }
  local got exp size files
  size="$(__file_size "$f")"
  if ! got="$(__calc_sha "$f")"; then return 4; fi
  if [[ -f "$i" ]]; then
    exp="$(__parse_kv "$i" "sha256" || true)"
    if [[ -n "$exp" && "$got" != "$exp" ]]; then
      __cache_err "verify_tarball: checksum divergente ($f)"
      return 4
    fi
    files="$(__parse_kv "$i" "files_count" || true)"
  fi
  __write_index "$i" \
    "key=BIN:${name}:${ver}:${profile}" \
    "sha256=${got}" \
    "size=${size}" \
    "created_at=$(__now_iso)" \
    "category=$(__parse_kv "$i" "category" || true)" \
    "files_count=${files}" || return 3
  adm_ok "verify_tarball: OK ($f)"
  return 0
}

###############################################################################
# API - GC e Stats
###############################################################################
adm_cache_gc() {
  # adm_cache_gc --type sources|tarballs|all [--max-age dias] [--max-size MB] [--dry-run]
  local type="all" max_age="" max_size_mb="" dry="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type) type="$2"; shift 2 ;;
      --max-age) max_age="$2"; shift 2 ;;
      --max-size) max_size_mb="$2"; shift 2 ;;
      --dry-run) dry="true"; shift ;;
      *) __cache_err "gc: opção desconhecida $1"; return 2 ;;
    esac
  done

  local removed=0 listed=0 bytes_total=0
  local do_sources=false do_bins=false
  case "$type" in
    sources) do_sources=true ;;
    tarballs) do_bins=true ;;
    all) do_sources=true; do_bins=true ;;
    *) __cache_err "gc: tipo inválido: $type"; return 2 ;;
  esac

  # Função interna para processar um diretório
  __gc_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    # 1) remover órfãos (index sem arquivo e vice-versa)
    shopt -s nullglob
    for idx in "$dir"/*.index; do
      local data="${idx%.index}"
      if [[ ! -f "$data" ]]; then
        [[ "$dry" == "true" ]] && { echo "(dry-run) rm $idx"; ((listed++)); } || { rm -f -- "$idx" && ((removed++)); }
      fi
    done
    for data in "$dir"/*; do
      [[ -f "$data" ]] || continue
      [[ "$data" == *.index ]] && continue
      local idx="${data}.index"
      if [[ ! -f "$idx" ]]; then
        [[ "$dry" == "true" ]] && { echo "(dry-run) rm $data"; ((listed++)); } || { rm -f -- "$data" && ((removed++)); }
      fi
    done

    # 2) max-age: eliminar antigos (baseado em mtime do arquivo de dados)
    if [[ -n "$max_age" ]]; then
      find "$dir" -type f ! -name '*.index' -mtime +"$max_age" -print0 2>/dev/null | while IFS= read -r -d '' data; do
        local idx="${data}.index"
        if [[ "$dry" == "true" ]]; then
          echo "(dry-run) rm $data"; ((listed++))
          [[ -f "$idx" ]] && { echo "(dry-run) rm $idx"; ((listed++)); }
        else
          rm -f -- "$data" && ((removed++))
          [[ -f "$idx" ]] && { rm -f -- "$idx" && ((removed++)); }
        fi
      done
    fi

    # 3) max-size: se tamanho total passar do limite, remover mais antigos
    if [[ -n "$max_size_mb" ]]; then
      local limit=$((max_size_mb * 1024 * 1024))
      local total
      total=$(du -sb -- "$dir" 2>/dev/null | awk '{print $1}')
      [[ -z "$total" ]] && total=0
      if (( total > limit )); then
        # ordenar por mtime crescente e remover até cair abaixo do limite
        local current="$total"
        # shellcheck disable=SC2012
        ls -1tr -- "$dir" 2>/dev/null | while read -r base; do
          local path="${dir%/}/$base"
          [[ -f "$path" ]] || continue
          if [[ "$path" == *.index ]]; then
            continue
          fi
          local size="$(__file_size "$path")"
          local idx="${path}.index"
          if [[ "$dry" == "true" ]]; then
            echo "(dry-run) rm $path"; ((listed++))
            [[ -f "$idx" ]] && { echo "(dry-run) rm $idx"; ((listed++)); }
          else
            rm -f -- "$path" && ((removed++))
            [[ -f "$idx" ]] && { rm -f -- "$idx" && ((removed++)); }
          fi
          current=$(( current - size ))
          if (( current <= limit )); then break; fi
        done
      fi
    fi
  }

  $do_sources && __gc_dir "$ADM_CACHE_SOURCES"
  $do_bins    && __gc_dir "$ADM_CACHE_TARBALLS"

  if [[ "$dry" == "true" ]]; then
    adm_ok "gc(dry-run) listados=$listed"
  else
    adm_ok "gc removidos=$removed"
  fi
  return 0
}

adm_cache_stats() {
  local s_count=0 s_bytes=0 b_count=0 b_bytes=0 orf=0
  if [[ -d "$ADM_CACHE_SOURCES" ]]; then
    s_count=$(find "$ADM_CACHE_SOURCES" -type f ! -name '*.index' 2>/dev/null | wc -l)
    s_bytes=$(du -sb -- "$ADM_CACHE_SOURCES" 2>/dev/null | awk '{print $1}')
    # órfãos
    orf=$(( orf + $(find "$ADM_CACHE_SOURCES" -type f -name '*.index' ! -exec test -f "{}".index \; -print 2>/dev/null | wc -l) ))
  fi
  if [[ -d "$ADM_CACHE_TARBALLS" ]]; then
    b_count=$(find "$ADM_CACHE_TARBALLS" -type f ! -name '*.index' 2>/dev/null | wc -l)
    b_bytes=$(du -sb -- "$ADM_CACHE_TARBALLS" 2>/dev/null | awk '{print $1}')
    orf=$(( orf + $(find "$ADM_CACHE_TARBALLS" -type f -name '*.index' ! -exec test -f "{}".index \; -print 2>/dev/null | wc -l) ))
  fi
  echo "sources: files=$s_count size_bytes=${s_bytes:-0}"
  echo "tarballs: files=$b_count size_bytes=${b_bytes:-0}"
  echo "orphans(index-missing): $orf"
  return 0
}

###############################################################################
# Marcar como carregado
###############################################################################
ADM_CACHE_LOADED=1
export ADM_CACHE_LOADED
