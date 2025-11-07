#!/usr/bin/env bash
# 04-adm-metafile.part1.sh
# Leitura, validação e acesso ao metafile KEY=VALUE.
# Requer: 00-adm-config.sh (ADM_CONF_LOADED) e 01-adm-lib.sh (ADM_LIB_LOADED)

###############################################################################
# Guardas e pré-requisitos
###############################################################################
if [[ -n "${ADM_META_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_META_LOADED_PART1=1

if [[ -z "${ADM_CONF_LOADED:-}" ]]; then
  echo "ERRO: 04-adm-metafile requer 00-adm-config.sh carregado." >&2
  return 2 2>/dev/null || exit 2
fi
if [[ -z "${ADM_LIB_LOADED:-}" ]]; then
  echo "ERRO: 04-adm-metafile requer 01-adm-lib.sh carregado." >&2
  return 2 2>/dev/null || exit 2
fi

###############################################################################
# Estado interno
###############################################################################
# Mapa chave->valor do metafile carregado
declare -Ag ADM_META
# Lista de chaves preservando ordem (para debug/inspeção)
declare -ag ADM_META_ORDER

# Metadados do arquivo carregado
ADM_META_FILE=""
ADM_META_BASEDIR=""
ADM_META_CAT=""
ADM_META_NAME=""
ADM_META_VERSION=""
ADM_META_VALID=0

# Regras/constantes
__META_REQUIRED_KEYS=(name version category build_type num_builds)
__META_LIST_KEYS=(run_deps build_deps opt_deps sources sha256sums)
__META_ALLOWED_BUILD_TYPES=${ADM_BUILD_TYPES:-"autotools cmake make meson cargo go python node custom"}

###############################################################################
# Helpers gerais
###############################################################################
__m_err()  { adm_err "$*"; }
__m_warn() { adm_warn "$*"; }
__m_info() { adm_log INFO "${ADM_META_NAME:-}" "metafile" "$*"; }

__m_trim() {
  local s="$*"
  # remove espaços à esquerda/direita
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

__m_is_under_root() {
  # __m_is_under_root <path> <root>
  local p="$1" root="$2"
  [[ -z "$p" || -z "$root" ]] && return 1
  local ap rp
  ap="$(cd -P -- "$(dirname -- "$p")" && pwd)/$(basename -- "$p")" || return 1
  rp="$(cd -P -- "$root" && pwd)" || return 1
  [[ "$ap" == "$rp"* ]]
}

__m_validate_pkg_name() {
  local n="$1"
  [[ "$n" =~ ^[a-zA-Z0-9._+\-]+$ ]]
}
__m_validate_version() {
  local v="$1"
  [[ -n "$v" ]] && [[ ! "$v" =~ [[:space:]]|, ]]
}
__m_validate_dep_token() {
  local t="$1"
  # nome ou nome@versao (sem espaços)
  [[ "$t" =~ ^[a-zA-Z0-9._+\-]+(@[a-zA-Z0-9._+\-]+)?$ ]]
}

__m_split_csv_array() {
  # __m_split_csv_array "<csv>" arrname
  local csv="$1" an="$2"
  # quebra por vírgula, aparando espaços de cada item
  local IFS=','; read -r -a __items <<< "$csv"
  local out=()
  local it
  for it in "${__items[@]}"; do
    it="$(__m_trim "$it")"
    [[ -n "$it" ]] && out+=( "$it" )
  done
  eval "$an=()"
  local i
  for i in "${out[@]}"; do
    eval "$an+=(\"\$i\")"
  done
}

__m_key_present() {
  local k="$1"
  [[ -n "${ADM_META[$k]+_}" ]]
}

__m_kv_set_once() {
  # guarda primeira ocorrência; duplicatas geram aviso e são ignoradas
  local k="$1" v="$2"
  if __m_key_present "$k"; then
    __m_warn "chave duplicada ignorada: '$k' (mantendo valor anterior)"
    return 0
  fi
  ADM_META["$k"]="$v"
  ADM_META_ORDER+=( "$k" )
}

__m_print_pkg_head() {
  local cat="${ADM_META_CAT:-}" name="${ADM_META_NAME:-}" ver="${ADM_META_VERSION:-}"
  local head=""
  if [[ -n "$cat" && -n "$name" && -n "$ver" ]]; then
    head="[$cat/$name $ver]"
  elif [[ -n "$name" && -n "$ver" ]]; then
    head="[$name $ver]"
  elif [[ -n "$name" ]]; then
    head="[$name]"
  fi
  [[ -n "$head" ]] && printf "%s " "$head"
  return 0
}

###############################################################################
# Localização do pacote e do metafile
###############################################################################
adm_meta_path() {
  # adm_meta_path <category> <name>
  local cat="$1" name="$2"
  [[ -z "$cat" || -z "$name" ]] && { __m_err "meta_path: parâmetros ausentes"; return 2; }
  # sanear: evitar path traversal
  cat="$(adm_sanitize_name "$cat")"
  name="$(adm_sanitize_name "$name")"
  local base="${ADM_META_ROOT%/}/${cat}/${name}"
  local mf="${base}/metafile"
  if [[ -f "$mf" ]]; then
    printf "%s\n" "$base"
    return 0
  fi
  return 1
}

adm_meta_find_any() {
  # adm_meta_find_any <name>
  local name="$1"
  [[ -z "$name" ]] && { __m_err "meta_find_any: nome ausente"; return 2; }
  name="$(adm_sanitize_name "$name")"
  local matches=()
  local d
  shopt -s nullglob
  for d in "${ADM_META_ROOT%/}"/*/"$name"; do
    [[ -f "$d/metafile" ]] && matches+=( "$d" )
  done
  shopt -u nullglob
  if (( ${#matches[@]} == 0 )); then
    return 1
  elif (( ${#matches[@]} > 1 )); then
    __m_err "múltiplas categorias para '$name': ${matches[*]}; use <categoria>/$name"
    return 4
  else
    printf "%s\n" "${matches[0]}"
    return 0
  fi
}

###############################################################################
# Leitura do metafile (KEY=VALUE)
###############################################################################
adm_meta_load() {
  # adm_meta_load <metafile_path>
  local mf="$1"
  [[ -z "$mf" ]] && { __m_err "meta_load: caminho do metafile ausente"; return 2; }
  [[ -f "$mf" ]] || { __m_err "meta_load: arquivo não encontrado: $mf"; return 3; }

  # segurança: garantir que está sob ADM_META_ROOT
  if ! __m_is_under_root "$mf" "$ADM_META_ROOT"; then
    __m_err "meta_load: arquivo fora de ADM_META_ROOT ($ADM_META_ROOT)"
    return 5
  fi

  # reset do estado anterior
  ADM_META=()
  ADM_META_ORDER=()
  ADM_META_FILE="$mf"
  ADM_META_BASEDIR="$(dirname -- "$mf")"
  ADM_META_CAT=""
  ADM_META_NAME=""
  ADM_META_VERSION=""
  ADM_META_VALID=0

  local line lineno=0
  # ler, ignorar linhas iniciadas por '#', aceitar KEY=VALUE
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno+1))
    # limitar linhas absurdamente grandes (defensivo)
    if ((${#line} > 65536)); then
      __m_err "metafile: linha $lineno muito longa (>64KiB)"
      return 2
    fi
    # ignorar comentários e linhas em branco
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue

    # separar na primeira ocorrência de '='
    if [[ "$line" != *"="* ]]; then
      __m_err "metafile: linha $lineno sem '='"
      return 2
    fi
    local k="${line%%=*}"
    local v="${line#*=}"

    k="$(__m_trim "$k")"
    v="$(__m_trim "$v")"

    if [[ -z "$k" ]]; then
      __m_err "metafile: linha $lineno com chave vazia"
      return 2
    fi

    # guardar (primeiro vence)
    __m_kv_set_once "$k" "$v"
  done < "$mf"

  # preencher campos de cabeçalho para mensagens
  ADM_META_NAME="${ADM_META[name]:-}"
  ADM_META_VERSION="${ADM_META[version]:-}"
  ADM_META_CAT="${ADM_META[category]:-}"

  # validação pós-parse
  if ! adm_meta_validate_loaded; then
    return 4
  fi

  ADM_META_VALID=1
  __m_info "metafile carregado com sucesso"
  return 0
}

adm_meta_load_pkg() {
  # adm_meta_load_pkg <category> <name>
  local cat="$1" name="$2"
  [[ -z "$cat" || -z "$name" ]] && { __m_err "meta_load_pkg: parâmetros ausentes"; return 2; }
  local base
  if ! base="$(adm_meta_path "$cat" "$name")"; then
    __m_err "meta_load_pkg: pacote não encontrado em ${ADM_META_ROOT%/}/$cat/$name"
    return 1
  fi
  local mf="${base}/metafile"
  if ! adm_meta_load "$mf"; then
    return $?
  fi
  return 0
}
# 04-adm-metafile.part2.sh
# Continuação: getters, listas, pares sources/sha, validação e helpers de hooks/patches.
if [[ -n "${ADM_META_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_META_LOADED_PART2=1
###############################################################################
# Getters e listagem de chaves
###############################################################################
adm_meta_get() {
  # adm_meta_get <key>
  local k="$1"
  [[ -z "$k" ]] && { __m_err "meta_get: chave ausente"; return 2; }
  if __m_key_present "$k"; then
    printf "%s" "${ADM_META[$k]}"
    return 0
  fi
  return 1
}

adm_meta_has() {
  # adm_meta_has <key> → 0 se existe
  local k="$1"
  [[ -z "$k" ]] && { __m_err "meta_has: chave ausente"; return 2; }
  __m_key_present "$k"
}

adm_meta_keys() {
  local k
  for k in "${ADM_META_ORDER[@]}"; do
    printf "%s\n" "$k"
  done
}

###############################################################################
# Listas (CSV → itens por linha)
###############################################################################
adm_meta_list() {
  # adm_meta_list <key>
  local k="$1"
  [[ -z "$k" ]] && { __m_err "meta_list: chave ausente"; return 2; }
  if ! __m_key_present "$k"; then
    return 1
  fi
  local csv="${ADM_META[$k]}"
  local arr
  __m_split_csv_array "$csv" arr
  local it
  for it in "${arr[@]}"; do
    printf "%s\n" "$it"
  done
  return 0
}

adm_meta_sources_count() {
  local csv="${ADM_META[sources]:-}"
  local arr
  __m_split_csv_array "$csv" arr
  echo "${#arr[@]}"
}

adm_meta_sha_count() {
  local csv="${ADM_META[sha256sums]:-}"
  local arr
  __m_split_csv_array "$csv" arr
  echo "${#arr[@]}"
}

adm_meta_pair_sources() {
  # imprime: i=<idx> url=<url> sha=<hash|->
  local srcs_csv="${ADM_META[sources]:-}"
  local shas_csv="${ADM_META[sha256sums]:-}"
  local srcs shas
  __m_split_csv_array "$srcs_csv" srcs
  __m_split_csv_array "$shas_csv" shas
  local n="${#srcs[@]}"
  local i=0
  for ((i=0;i<n;i++)); do
    local url="${srcs[$i]}"
    local sha="-"
    [[ -n "${shas[$i]:-}" ]] && sha="${shas[$i]}"
    printf 'i=%d url=%s sha=%s\n' "$i" "$url" "$sha"
  done
  return 0
}

###############################################################################
# Validação (público)
###############################################################################
adm_meta_validate_loaded() {
  # 1) chaves obrigatórias
  local k
  for k in "${__META_REQUIRED_KEYS[@]}"; do
    if ! __m_key_present "$k"; then
      __m_err "metafile: missing required key '$k'"
      return 4
    fi
  done

  local name="${ADM_META[name]}"
  local ver="${ADM_META[version]}"
  local cat="${ADM_META[category]}"
  local btype="${ADM_META[build_type]}"
  local num="${ADM_META[num_builds]}"

  # 2) name
  if ! __m_validate_pkg_name "$name"; then
    __m_err "metafile: invalid name '$name' (permitido: [a-zA-Z0-9._+-])"
    return 4
  fi

  # 3) version
  if ! __m_validate_version "$ver"; then
    __m_err "metafile: invalid version '$ver' (sem espaços/vírgulas)"
    return 4
  fi

  # 4) category (apenas sem espaços)
  if [[ -z "$cat" || "$cat" =~ [[:space:]] ]]; then
    __m_err "metafile: invalid category '$cat'"
    return 4
  fi

  # 5) build_type ∈ lista
  local ok=1 x
  for x in $__META_ALLOWED_BUILD_TYPES; do
    if [[ "$x" == "$btype" ]]; then ok=0; break; fi
  done
  if (( ok != 0 )); then
    __m_err "metafile: unsupported build_type '$btype' (válidos: $__META_ALLOWED_BUILD_TYPES)"
    return 4
  fi

  # 6) num_builds inteiro ≥ 0
  if ! [[ "$num" =~ ^[0-9]+$ ]]; then
    __m_err "metafile: invalid num_builds '$num' (inteiro ≥ 0)"
    return 4
  fi

  # 7) lists: sources & sha256sums cardinalidade
  local ns="$(adm_meta_sources_count)"
  local nh="$(adm_meta_sha_count)"
  if [[ -n "${ADM_META[sources]:-}" && -n "${ADM_META[sha256sums]:-}" ]]; then
    if (( ns != nh )); then
      __m_err "metafile: sha256sums count ($nh) != sources count ($ns)"
      return 4
    fi
  fi

  # 8) deps tokens
  local depk depcsv arr it
  for depk in run_deps build_deps opt_deps; do
    depcsv="${ADM_META[$depk]:-}"
    __m_split_csv_array "$depcsv" arr
    for it in "${arr[@]}"; do
      if ! __m_validate_dep_token "$it"; then
        __m_err "metafile: invalid dependency token '$it' em '$depk'"
        return 4
      fi
    done
  done

  # 9) homepage se presente
  if __m_key_present "homepage"; then
    local hp="${ADM_META[homepage]}"
    if [[ -n "$hp" && ! "$hp" =~ ^https?:// ]]; then
      __m_warn "metafile: homepage não http(s): '$hp'"
    end
  fi

  # 10) chaves desconhecidas → aviso (mas aceitas)
  local known=" name version category build_type run_deps build_deps opt_deps num_builds description homepage maintainer sha256sums sources "
  for k in "${ADM_META_ORDER[@]}"; do
    if [[ "$known" != *" $k "* ]]; then
      __m_warn "metafile: chave desconhecida '$k' será ignorada por padrão"
    fi
  done

  return 0
}

###############################################################################
# Hooks e patches
###############################################################################
adm_meta_hooks_dir() {
  # imprime caminho do diretório hooks/ (se existir), senão vazio
  local d="${ADM_META_BASEDIR%/}/hooks"
  [[ -d "$d" ]] && printf "%s\n" "$d" || printf ""
  return 0
}
adm_meta_patches_dir() {
  local d="${ADM_META_BASEDIR%/}/patches"
  [[ -d "$d" ]] && printf "%s\n" "$d" || printf ""
  return 0
}

###############################################################################
# Execução direta (debug opcional)
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  sub="${1:-}"; shift || true
  case "$sub" in
    load)
      adm_meta_load "$1" || exit $?
      echo "OK";;
    loadpkg)
      adm_meta_load_pkg "$1" "$2" || exit $?
      echo "OK";;
    show)
      adm_meta_keys | while read -r k; do
        printf "%s=%s\n" "$k" "${ADM_META[$k]}"
      done;;
    pairs)
      adm_meta_pair_sources;;
    *)
      echo "uso:" >&2
      echo "  $0 load <path/metafile>" >&2
      echo "  $0 loadpkg <category> <name>" >&2
      echo "  $0 show   (mostra KV atuais)" >&2
      echo "  $0 pairs  (lista i=<n> url=<url> sha=<hash|->)" >&2
      ;;
  esac
fi

###############################################################################
# Marcar como carregado
###############################################################################
ADM_META_LOADED=1
export ADM_META_LOADED
