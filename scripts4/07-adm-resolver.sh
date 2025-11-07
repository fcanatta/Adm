#!/usr/bin/env bash
# 07-adm-resolver.part1.sh
# Resolve dependências (build/run/opt/tool), detecta conflitos/ciclos,
# escolhe binário x source, respeita perfis/políticas, e gera plan/lock/graph.
# Requer: 00-adm-config.sh, 01-adm-lib.sh, 04-adm-metafile.sh
###############################################################################
# Guardas e pré-requisitos
###############################################################################
if [[ -n "${ADM_RESOLVER_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_RESOLVER_LOADED_PART1=1

if [[ -z "${ADM_CONF_LOADED:-}" ]]; then
  echo "ERRO: 07-adm-resolver requer 00-adm-config.sh carregado." >&2
  return 2 2>/dev/null || exit 2
fi
if [[ -z "${ADM_LIB_LOADED:-}" ]]; then
  echo "ERRO: 07-adm-resolver requer 01-adm-lib.sh carregado." >&2
  return 2 2>/dev/null || exit 2
fi
if [[ -z "${ADM_META_LOADED:-}" ]]; then
  echo "AVISO: 07-adm-resolver foi carregado antes do 04-adm-metafile.sh; "\
       "funções de leitura exigem adm_meta_load/_pkg." >&2
fi

###############################################################################
# Configurações (defaults robustos)
###############################################################################
: "${ADM_BIN_CACHE_ROOT:=${ADM_CACHE_ROOT:-/usr/src/adm/cache}/bin}"
: "${ADM_PLAN_ROOT:=${ADM_STATE_ROOT:-/usr/src/adm/state}/plan}"
: "${ADM_LOCK_ROOT:=${ADM_STATE_ROOT:-/usr/src/adm/state}/lock}"
: "${ADM_GRAPH_ROOT:=${ADM_STATE_ROOT:-/usr/src/adm/state}/graph}"

# Política
: "${ADM_PROFILE_DEFAULT:=normal}"       # minimal|normal|aggressive
: "${ADM_MODE_BIN_FIRST:=true}"          # bin-first por padrão
: "${ADM_OFFLINE:=false}"                # somente o que já existe localmente

###############################################################################
# Estado interno do resolver
###############################################################################
# Nó é "cat/name@version"
declare -Ag R_CFG=(
  [profile]="" [bin_only]="false" [source_only]="false" [with_opts]="false"
  [strict]="false" [offline]="" [update]="false"
)
declare -Ag R_TARGET=([cat]="" [name]="" [version]="")
declare -Ag R_STATS=([nodes]=0 [edges]=0 [start]=0 [end]=0)

# Grafo
declare -Ag R_NODE_ID          # key "cat/name@ver" -> small int id
declare -Ag R_NODE_KEY         # id -> key "cat/name@ver"
declare -Ag R_NODE_META        # id -> path metafile
declare -Ag R_NODE_ORIGIN      # id -> bin|source (decidido depois)
declare -Ag R_NODE_CAT         # id -> category
declare -Ag R_NODE_NAME        # id -> name
declare -Ag R_NODE_VER         # id -> version
declare -Ag R_NODE_DEPS_BUILD  # id -> "cat/name,cat2/name2"
declare -Ag R_NODE_DEPS_RUN    # id -> csv
declare -Ag R_NODE_DEPS_OPT    # id -> csv
declare -Ag R_NODE_DEPS_TOOL   # id -> csv

# Arestas (adj list)
declare -Ag R_ADJ              # "id" -> "id1,id2,..."
declare -Ag R_COLOR            # DFS colors: WHITE/GRAY/BLACK
declare -Ag R_INDEG            # Kahn indegree

# Lock/pins (nome normalizado -> versão)
declare -Ag R_LOCK

# Virtuals (simples): virtual -> preferências (por perfil)
# Você pode expandir isso depois via arquivo; aqui tem um seed útil.
declare -Ag R_VIRTUAL_PREF
R_VIRTUAL_PREF[jpeg:aggressive]="libjpeg-turbo"
R_VIRTUAL_PREF[jpeg:normal]="libjpeg"
R_VIRTUAL_PREF[jpeg:minimal]="libjpeg"
# fallback genérico
R_VIRTUAL_PREF[jpeg:_]="libjpeg"

###############################################################################
# Helpers básicos
###############################################################################
res_err()   { adm_err "$*"; }
res_warn()  { adm_warn "$*"; }
res_info()  { adm_log INFO "${R_TARGET[name]:-}" "resolver" "$*"; }

res_sanitize() {
  local s="$1"; adm_sanitize_name "$s"
}

res_key() { printf "%s/%s@%s" "$1" "$2" "$3"; }

res_norm() {
  # normaliza nomes simples (coeso com 06-adm-analyze)
  local n="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  case "$n" in
    libz|zlib1) echo "zlib";;
    libpng|libpng16) echo "libpng";;
    libssl|openssl3|openssl11) echo "openssl";;
    libcurl) echo "curl";;
    jpeg|libjpeg|libjpeg-turbo) echo "jpeg";;   # virtual
    libsqlite3|sqlite) echo "sqlite3";;
    pcre) echo "pcre";;
    pcre2-*) echo "pcre2";;
    qt5-*) echo "qt5";;
    qt6-*) echo "qt6";;
    *) echo "$n";;
  esac
}

res_push_csv_unique() {
  # res_push_csv_unique "<csvvarname>" "<value>"
  local vn="$1" val="$2"
  [[ -z "$val" ]] && return 0
  local csv="${!vn}"
  IFS=',' read -r -a arr <<<"$csv"
  local x; for x in "${arr[@]}"; do [[ "$x" == "$val" ]] && { printf -v "$vn" "%s" "$csv"; return 0; }; done
  if [[ -z "$csv" ]]; then printf -v "$vn" "%s" "$val"
  else printf -v "$vn" "%s,%s" "$csv" "$val"
  fi
}

res_csv_sort_unique() {
  local csv="$1"
  [[ -z "$csv" ]] && { echo ""; return 0; }
  echo "$csv" | tr ',' '\n' | awk 'NF' | sort -u | paste -sd, -
}

res_profile() { echo "${R_CFG[profile]:-$ADM_PROFILE_DEFAULT}"; }

res_now_s() { date +%s 2>/dev/null || printf "%d" "$(($(date +%s%N 2>/dev/null)/1000000000))"; }

###############################################################################
# Carregar metafile de um pacote e extrair dados
###############################################################################
__res_load_pkg_meta() {
  # __res_load_pkg_meta <cat> <name> [<version?>]
  local cat="$1" name="$2" ver="${3:-}"
  [[ -z "$cat" || -z "$name" ]] && { res_err "load_meta: parâmetros ausentes"; return 2; }
  cat="$(res_sanitize "$cat")"; name="$(res_sanitize "$name")"
  local base
  if ! base="$(adm_meta_path "$cat" "$name")"; then
    res_err "metafile não encontrado: ${ADM_META_ROOT%/}/$cat/$name/metafile"
    return 1
  fi
  local mf="${base%/}/metafile"
  if ! adm_meta_load "$mf"; then
    res_err "falha ao carregar metafile de $cat/$name"
    return 3
  fi
  local mname mver mcat btype
  mname="$(adm_meta_get name || true)"
  mver="$(adm_meta_get version || true)"
  mcat="$(adm_meta_get category || true)"
  btype="$(adm_meta_get build_type || true)"
  [[ -z "$mname" || -z "$mver" || -z "$mcat" ]] && { res_err "metafile inválido em $mf"; return 3; }

  # Se versão foi pedida e difere, apenas avisa (lockfile pode ajustar depois)
  if [[ -n "$ver" && "$ver" != "$mver" ]]; then
    res_warn "versão solicitada ($ver) difere da do metafile ($mver) — usando $mver"
  fi

  # Extrair listas de deps
  local run build opt
  run="$(adm_meta_get run_deps 2>/dev/null || true)"
  build="$(adm_meta_get build_deps 2>/dev/null || true)"
  opt="$(adm_meta_get opt_deps 2>/dev/null || true)"

  # Normalizar nomes e montar csvs
  local out_run="" out_build="" out_opt=""
  IFS=',' read -r -a A <<<"$run"; for x in "${A[@]}"; do x="$(echo "$x"|xargs)"; x="$(res_norm "$x")"; res_push_csv_unique out_run "$x"; done
  IFS=',' read -r -a B <<<"$build"; for x in "${B[@]}"; do x="$(echo "$x"|xargs)"; x="$(res_norm "$x")"; res_push_csv_unique out_build "$x"; done
  IFS=',' read -r -a C <<<"$opt"; for x in "${C[@]}"; do x="$(echo "$x"|xargs)"; x="$(res_norm "$x")"; res_push_csv_unique out_opt "$x"; done

  # Tool deps por build_type (heurístico)
  local tool=""
  case "$btype" in
    cmake) tool="cmake,ninja,pkg-config";;
    meson) tool="meson,ninja,pkg-config";;
    autotools) tool="autoconf,automake,libtool,pkg-config";;
    cargo) tool="cargo";;
    go) tool="go";;
    python) tool="python3";;
    node) tool="node";;
    java) tool="maven,gradle";;
    .net) tool="dotnet";;
    *) tool="";;
  esac

  # Retornar via stdout em formato chave=valor (shell-friendly)
  cat <<EOF
mname=$mname
mver=$mver
mcat=$mcat
build_type=$btype
run=$out_run
build=$out_build
opt=$out_opt
tool=$tool
metafile=$mf
EOF
  return 0
}

###############################################################################
# Descobrir versão (simplificado): usa a do metafile ou lock pinado
###############################################################################
__res_select_version() {
  # __res_select_version <cat> <name> [<preferred_ver>]
  local cat="$1" name="$2" pref="${3:-}"
  local base
  if ! base="$(adm_meta_path "$cat" "$name")"; then
    return 1
  fi
  local mf="${base%/}/metafile"
  if ! adm_meta_load "$mf"; then
    return 3
  fi
  local mver; mver="$(adm_meta_get version || true)"
  # Lockfile vence se existir
  local key="${cat}/${name}"
  if [[ -n "${R_LOCK[$key]:-}" ]]; then
    echo "${R_LOCK[$key]}"; return 0
  fi
  if [[ -n "$pref" && "$pref" == "$mver" ]]; then
    echo "$pref"; return 0
  fi
  echo "$mver"
  return 0
}

###############################################################################
# Virtuals/provides (baseline simples com jpeg)
###############################################################################
__res_apply_virtuals() {
  # __res_apply_virtuals <dep>
  local dep="$(res_norm "$1")"
  case "$dep" in
    jpeg)
      local prof; prof="$(res_profile)"
      echo "${R_VIRTUAL_PREF[jpeg:${prof}]:-${R_VIRTUAL_PREF[jpeg:_]}}"
      return 0
      ;;
  esac
  echo "$dep"
  return 0
}

###############################################################################
# Status do nó (installed/bin-cache/source-available/missing)
###############################################################################
__res_bin_cache_path() {
  # __res_bin_cache_path <cat> <name> <ver>
  local cat="$1" name="$2" ver="$3"
  printf "%s/%s/%s-%s.tar.zst" "${ADM_BIN_CACHE_ROOT%/}" "$cat" "$name" "$ver"
}

__res_node_status() {
  # __res_node_status <cat> <name> <ver>
  local cat="$1" name="$2" ver="$3"
  local mfbase
  if adm_meta_path "$cat" "$name" >/dev/null 2>&1; then
    local bin; bin="$(__res_bin_cache_path "$cat" "$name" "$ver")"
    if [[ -f "$bin" ]]; then
      echo "bin-cache"; return 0
    fi
    echo "source-available"; return 0
  fi
  echo "missing"; return 1
}

###############################################################################
# Adiciona nó ao grafo (idempotente) e define metadados
###############################################################################
__res_add_node() {
  # __res_add_node <cat> <name> <ver>
  local cat="$1" name="$2" ver="$3"
  local key; key="$(res_key "$cat" "$name" "$ver")"
  if [[ -n "${R_NODE_ID[$key]:-}" ]]; then
    echo "${R_NODE_ID[$key]}"; return 0
  fi

  # Carrega dados do metafile
  local kv; if ! kv="$(__res_load_pkg_meta "$cat" "$name" "$ver")"; then
    return $?
  fi
  local m name2 ver2 cat2 run build opt tool mf btype
  eval "$kv" 2>/dev/null || true
  cat2="$mcat"; name2="$mname"; ver2="$mver"; mf="$metafile"; btype="$build_type"

  # Novo id
  local id="${R_STATS[nodes]}"; R_STATS[nodes]=$((id+1))
  R_NODE_ID["$key"]="$id"
  R_NODE_KEY["$id"]="$key"
  R_NODE_META["$id"]="$mf"
  R_NODE_CAT["$id"]="$cat2"
  R_NODE_NAME["$id"]="$name2"
  R_NODE_VER["$id"]="$ver2"
  R_NODE_DEPS_BUILD["$id"]="$(res_csv_sort_unique "$build")"
  R_NODE_DEPS_RUN["$id"]="$(res_csv_sort_unique "$run")"
  R_NODE_DEPS_OPT["$id"]="$(res_csv_sort_unique "$opt")"
  R_NODE_DEPS_TOOL["$id"]="$(res_csv_sort_unique "$tool")"
  R_ADJ["$id"]=""
  R_INDEG["$id"]=0

  echo "$id"
  return 0
}

###############################################################################
# Expansão de deps para um nó (apenas nomes; versão resolvida quando enfileirar)
###############################################################################
__res_expand_deps() {
  # __res_expand_deps <id> -> imprime linhas "class depname"
  local id="$1"
  local prof; prof="$(res_profile)"
  local addopt="false"
  [[ "${R_CFG[with_opts]}" == "true" || "$prof" == "aggressive" ]] && addopt="true"

  local x
  IFS=',' read -r -a A <<<"${R_NODE_DEPS_TOOL[$id]}"
  for x in "${A[@]}"; do [[ -n "$x" ]] && printf "tool %s\n" "$x"; done
  IFS=',' read -r -a B <<<"${R_NODE_DEPS_BUILD[$id]}"
  for x in "${B[@]}"; do [[ -n "$x" ]] && printf "build %s\n" "$x"; done
  IFS=',' read -r -a C <<<"${R_NODE_DEPS_RUN[$id]}"
  for x in "${C[@]}"; do [[ -n "$x" ]] && printf "run %s\n" "$x"; done

  if [[ "$addopt" == "true" ]]; then
    IFS=',' read -r -a D <<<"${R_NODE_DEPS_OPT[$id]}"
    for x in "${D[@]}"; do [[ -n "$x" ]] && printf "opt %s\n" "$x"; done
  fi
  return 0
}

###############################################################################
# Enfileirar dependência (nome -> nó), aplicando virtuals e escolhendo versão
###############################################################################
__res_enqueue_dep() {
  # __res_enqueue_dep <depname> <class> <parent_id>
  local dep="$1" class="$2" pid="$3"
  [[ -z "$dep" || -z "$class" || -z "$pid" ]] && { res_err "enqueue_dep: parâmetros ausentes"; return 2; }

  # Virtuals/provides (mínimo)
  dep="$(__res_apply_virtuals "$dep")"

  # versão (usa a do metafile)
  local dcat="$dep" dname="$dep"  # por padrão, deps não trazem categoria → buscar por todas
  # tentar descobrir categoria única
  local found=()
  local d
  shopt -s nullglob
  for d in "${ADM_META_ROOT%/}"/*/"$dep"; do
    [[ -f "$d/metafile" ]] && found+=( "$d" )
  done
  shopt -u nullglob
  if (( ${#found[@]} == 0 )); then
    res_err "dependência ausente: '$dep' requerida por ${R_NODE_KEY[$pid]}"
    return 1
  elif (( ${#found[@]} > 1 )); then
    res_warn "múltiplas categorias para '$dep' — escolhendo a primeira: ${found[0]#$ADM_META_ROOT/}"
  fi
  local base="${found[0]}"
  local cat="$(basename -- "$(dirname -- "$base")")"
  local ver; if ! ver="$(__res_select_version "$cat" "$dep")"; then
    res_err "não foi possível selecionar versão para $cat/$dep"
    return 3
  fi

  # adicionar nó
  local cid; if ! cid="$(__res_add_node "$cat" "$dep" "$ver")"; then
    return $?
  fi

  # criar aresta pid -> cid
  local cur="${R_ADJ[$pid]}"
  local list="$cur"
  local append="true"
  IFS=',' read -r -a M <<<"$cur"
  local m; for m in "${M[@]}"; do [[ "$m" == "$cid" ]] && append="false"; done
  if [[ "$append" == "true" ]]; then
    if [[ -z "$list" ]]; then list="$cid"; else list="$list,$cid"; fi
    R_ADJ["$pid"]="$list"
    R_INDEG["$cid"]=$(( ${R_INDEG[$cid]} + 1 ))
    R_STATS[edges]=$(( ${R_STATS[edges]} + 1 ))
  fi
  return 0
}

###############################################################################
# Construção do grafo recursivo + detecção de ciclos (DFS)
###############################################################################
__res_build_graph_rec() {
  # __res_build_graph_rec <id>
  local id="$1"
  local color="${R_COLOR[$id]:-WHITE}"
  if [[ "$color" == "GRAY" ]]; then
    res_err "ciclo detectado em ${R_NODE_KEY[$id]}"
    return 4
  elif [[ "$color" == "BLACK" ]]; then
    return 0
  fi
  R_COLOR["$id"]="GRAY"

  # Expandir deps deste nó
  local lines line class dep
  lines="$(__res_expand_deps "$id")" || return $?
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    class="${line%% *}"; dep="${line#* }"; dep="$(res_norm "$dep")"
    if ! __res_enqueue_dep "$dep" "$class" "$id"; then
      return $?
    fi
    local cid="${R_ADJ[$id]##*,}" # último inserido (ou único)
    # Recurse no filho
    if [[ -n "$cid" ]]; then
      if ! __res_build_graph_rec "$cid"; then
        return $?
      fi
    fi
  done <<< "$lines"

  R_COLOR["$id"]="BLACK"
  return 0
}
# 07-adm-resolver.part2.sh
# Continuação: toposort, origem bin/source, emissão de plan/graph/lock e CLI.
if [[ -n "${ADM_RESOLVER_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_RESOLVER_LOADED_PART2=1
###############################################################################
# Topological sort (Kahn)
###############################################################################
__res_toposort() {
  local -a Q=() ORDER=()
  local id
  for id in "${!R_NODE_KEY[@]}"; do
    if (( ${R_INDEG[$id]:-0} == 0 )); then
      Q+=( "$id" )
    fi
  done
  while ((${#Q[@]})); do
    local u="${Q[0]}"
    Q=( "${Q[@]:1}" )
    ORDER+=( "$u" )
    local adj="${R_ADJ[$u]}"
    IFS=',' read -r -a NBR <<<"$adj"
    local v
    for v in "${NBR[@]}"; do
      [[ -z "$v" ]] && continue
      R_INDEG["$v"]=$(( ${R_INDEG[$v]} - 1 ))
      if (( ${R_INDEG[$v]} == 0 )); then
        Q+=( "$v" )
      fi
    done
  done
  # Verificar se cobriu todos
  if ((${#ORDER[@]} != ${#R_NODE_KEY[@]})); then
    res_err "grafo possui ciclo ou indegree inconsistente (ordem parcial)"
    return 4
  fi
  printf "%s\n" "${ORDER[@]}"
  return 0
}

###############################################################################
# Decisão de origem (binário x source) respeitando políticas
###############################################################################
__res_pick_origin() {
  # __res_pick_origin <id>
  local id="$1"
  local cat="${R_NODE_CAT[$id]}" name="${R_NODE_NAME[$id]}" ver="${R_NODE_VER[$id]}"
  local status; status="$(__res_node_status "$cat" "$name" "$ver")" || status="missing"
  case "$status" in
    bin-cache)
      R_NODE_ORIGIN["$id"]="bin"
      return 0;;
    source-available)
      if [[ "${R_CFG[bin_only]}" == "true" ]]; then
        res_err "modo --bin-only: binário ausente para $cat/$name@$ver"
        return 5
      fi
      if [[ "${R_CFG[offline]:-$ADM_OFFLINE}" == "true" ]]; then
        # source-available (metafile presente) está OK offline (downloads ocorrem no build; resolver apenas planeja)
        R_NODE_ORIGIN["$id"]="source"
        return 0
      fi
      if [[ "${R_CFG[source_only]}" == "true" ]]; then
        R_NODE_ORIGIN["$id"]="source"; return 0
      fi
      if [[ "${ADM_MODE_BIN_FIRST}" == "true" ]]; then
        R_NODE_ORIGIN["$id"]="source"; return 0
      else
        # fallback; aqui equivalem
        R_NODE_ORIGIN["$id"]="source"; return 0
      fi
      ;;
    missing)
      res_err "pacote ausente no repositório: $name (não encontrado em ${ADM_META_ROOT%/}/*/$name)"
      return 1;;
    *)
      R_NODE_ORIGIN["$id"]="source"; return 0;;
  esac
}

###############################################################################
# Emissão do planfile
###############################################################################
__res_plan_path() {
  local cat="$1" name="$2" ver="$3"
  printf "%s/%s_%s-%s.plan" "${ADM_PLAN_ROOT%/}" "$cat" "$name" "$ver"
}

__res_emit_plan() {
  # __res_emit_plan <order_ids...>
  mkdir -p -- "$ADM_PLAN_ROOT" "$ADM_LOCK_ROOT" "$ADM_GRAPH_ROOT" 2>/dev/null || true
  local cat="${R_TARGET[cat]}" name="${R_TARGET[name]}" ver="${R_TARGET[version]}"
  local plan; plan="$(__res_plan_path "$cat" "$name" "$ver")"
  : > "$plan" || { res_err "não foi possível criar planfile: $plan"; return 3; }

  local id
  for id in "$@"; do
    local oc="${R_NODE_CAT[$id]}" on="${R_NODE_NAME[$id]}" ov="${R_NODE_VER[$id]}"
    local origin="${R_NODE_ORIGIN[$id]}"
    if [[ "$origin" == "bin" ]]; then
      local bin="$(__res_bin_cache_path "$oc" "$on" "$ov")"
      printf "STEP install %s/%s@%s origin=bin cache=%s\n" "$oc" "$on" "$ov" "$bin" >> "$plan"
    else
      local mf="${R_NODE_META[$id]}"
      printf "STEP build %s/%s@%s origin=source metafile=%s\n" "$oc" "$on" "$ov" "$mf" >> "$plan"
    fi
  done
  echo "$plan"
  return 0
}

###############################################################################
# Emissão de lockfile
###############################################################################
__res_lock_path() {
  local cat="$1" name="$2"
  printf "%s/%s_%s.lock" "${ADM_LOCK_ROOT%/}" "$cat" "$name"
}

__res_write_lockfile() {
  local cat="${R_TARGET[cat]}" name="${R_TARGET[name]}"
  local p="$(__res_lock_path "$cat" "$name")"
  : > "$p" || { res_warn "não foi possível escrever lockfile: $p"; return 3; }
  local id
  for id in "${!R_NODE_KEY[@]}"; do
    printf "%s@%s\n" "${R_NODE_NAME[$id]}" "${R_NODE_VER[$id]}" >> "$p"
  done
  echo "$p"
  return 0
}

###############################################################################
# Emissão do grafo (ascii e dot)
###############################################################################
__res_emit_graph_ascii() {
  local id
  for id in "${!R_NODE_KEY[@]}"; do
    local k="${R_NODE_KEY[$id]}"
    printf "%s\n" "$k"
    local adj="${R_ADJ[$id]}"
    IFS=',' read -r -a A <<<"$adj"
    local v
    for v in "${A[@]}"; do
      [[ -z "$v" ]] && continue
      printf "  └─> %s\n" "${R_NODE_KEY[$v]}"
    done
  done
}

__res_emit_graph_dot() {
  echo "digraph deps {"
  echo "  rankdir=LR;"
  local id
  for id in "${!R_NODE_KEY[@]}"; do
    local label="${R_NODE_KEY[$id]}"
    echo "  n$id [label=\"$label\"];"
  done
  for id in "${!R_NODE_KEY[@]}"; do
    IFS=',' read -r -a A <<<"${R_ADJ[$id]}"
    local v
    for v in "${A[@]}"; do
      [[ -z "$v" ]] && continue
      echo "  n$id -> n$v;"
    done
  done
  echo "}"
}

###############################################################################
# Resumo colorido/bonito (extras de qualidade)
###############################################################################
__res_print_summary() {
  local plan_path="$1"
  local prof; prof="$(res_profile)"
  local mode="bin-first"
  [[ "${R_CFG[bin_only]}" == "true" ]] && mode="bin-only"
  [[ "${R_CFG[source_only]}" == "true" ]] && mode="source-only"
  [[ "${R_CFG[offline]:-$ADM_OFFLINE}" == "true" ]] && mode="${mode}+offline"

  adm_step "${R_TARGET[name]}" "${R_TARGET[version]}" "Resumo do plano"
  echo "alvo=${R_TARGET[cat]}/${R_TARGET[name]}@${R_TARGET[version]} profile=${prof} mode=${mode}"
  local build="" run="" opt="" tool=""
  local id
  # Agregamos deps top-level do target (para resumo)
  local tid; tid="${R_NODE_ID[$(res_key "${R_TARGET[cat]}" "${R_TARGET[name]}" "${R_TARGET[version]}")]}"
  build="${R_NODE_DEPS_BUILD[$tid]}"
  run="${R_NODE_DEPS_RUN[$tid]}"
  opt="${R_NODE_DEPS_OPT[$tid]}"
  tool="${R_NODE_DEPS_TOOL[$tid]}"
  build="$(res_csv_sort_unique "$build")"
  run="$(res_csv_sort_unique "$run")"
  if [[ "${R_CFG[with_opts]}" == "true" || "$(res_profile)" == "aggressive" ]]; then
    opt="$(res_csv_sort_unique "$opt")"
  else
    opt=""
  fi
  tool="$(res_csv_sort_unique "$tool")"

  adm_log DEP "${R_TARGET[name]}" "resolver" "$(printf "build: \e[95;1m%s\e[0m | run: \e[95;1m%s\e[0m | opt: \e[95;1m%s\e[0m | tool: \e[95;1m%s\e[0m" "${build:-"-"}" "${run:-"-"}" "${opt:-"-"}" "${tool:-"-"}")"
  echo "PLANFILE: $plan_path"
}

###############################################################################
# Comando principal: gerar plano
###############################################################################
adm_resolve_plan() {
  local cat="$1" name="$2"; shift 2 || true
  [[ -z "$cat" || -z "$name" ]] && { res_err "uso: plan <cat> <name> [flags]"; return 2; }
  R_TARGET[cat]="$(res_sanitize "$cat")"
  R_TARGET[name]="$(res_sanitize "$name")"
  R_CFG[profile]="$ADM_PROFILE_DEFAULT"
  R_CFG[offline]="$ADM_OFFLINE"

  # Flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) R_TARGET[version]="$2"; shift 2;;
      --profile) R_CFG[profile]="$2"; shift 2;;
      --with-opts) R_CFG[with_opts]="true"; shift;;
      --no-opts) R_CFG[with_opts]="false"; shift;;
      --bin-only) R_CFG[bin_only]="true"; R_CFG[source_only]="false"; shift;;
      --source-only) R_CFG[source_only]="true"; R_CFG[bin_only]="false"; shift;;
      --offline) R_CFG[offline]="true"; shift;;
      --strict) R_CFG[strict]="true"; shift;;
      --update) R_CFG[update]="true"; shift;;
      --lockfile) # carregar lock
        local lf="$2"; shift 2
        if [[ -f "$lf" ]]; then
          while read -r line; do
            [[ -z "$line" ]] && continue
            local nm="${line%@*}" vv="${line#*@}"
            R_LOCK["$nm"]="$vv"
          done < "$lf"
        else
          res_warn "lockfile não encontrado: $lf (ignorando)"
        fi
        ;;
      *) res_warn "opção desconhecida: $1 (ignorada)"; shift;;
    esac
  done

  R_STATS[start]="$(res_now_s)"

  # Adicionar nó alvo
  local ver
  if ! ver="$(__res_select_version "${R_TARGET[cat]}" "${R_TARGET[name]}" "${R_TARGET[version]}")"; then
    return $?
  fi
  R_TARGET[version]="$ver"
  local tid; if ! tid="$(__res_add_node "${R_TARGET[cat]}" "${R_TARGET[name]}" "$ver")"; then
    return $?
  fi

  # Construir grafo (DFS + expansão)
  adm_with_spinner "Construindo grafo de dependências..." -- __res_build_graph_rec "$tid" || return $?

  # Toposort
  local order
  if ! mapfile -t order < <(__res_toposort); then
    return $?
  fi

  # Decidir origem (bin|source) por nó
  local id
  for id in "${order[@]}"; do
    if ! __res_pick_origin "$id"; then
      return $?
    fi
  done

  # Emitir planfile
  local plan_file
  if ! plan_file="$(__res_emit_plan "${order[@]}")"; then
    return $?
  fi

  # Escrever lockfile (melhor esforço)
  __res_write_lockfile "${R_TARGET[cat]}" "${R_TARGET[name]}" >/dev/null 2>&1 || true

  # Resumo
  __res_print_summary "$plan_file"

  R_STATS[end]="$(res_now_s)"
  local dt=$(( R_STATS[end] - R_STATS[start] ))
  res_info "nós=${#R_NODE_KEY[@]} arestas=${R_STATS[edges]} tempo=${dt}s"
  adm_ok "resolução concluída"
  echo "$plan_file"
  return 0
}

###############################################################################
# Graph (ascii ou dot)
###############################################################################
adm_resolve_graph() {
  local cat="$1" name="$2"; shift 2 || true
  local fmt="ascii"
  [[ "$1" == "--format" && -n "$2" ]] && { fmt="$2"; shift 2; }
  # Gerar plano (sem emitir planfile) apenas para construir grafo
  if ! adm_resolve_plan "$cat" "$name" --profile "${R_CFG[profile]}" >/dev/null; then
    return $?
  fi
  case "$fmt" in
    ascii) __res_emit_graph_ascii;;
    dot)   __res_emit_graph_dot;;
    *) res_err "formato inválido: $fmt"; return 2;;
  esac
}

###############################################################################
# Check (dry-run de resolução)
###############################################################################
adm_resolve_check() {
  local cat="$1" name="$2"; shift 2 || true
  if ! adm_resolve_plan "$cat" "$name" "$@" >/dev/null; then
    return $?
  fi
  adm_ok "check: resolução OK para $cat/$name"
  return 0
}

###############################################################################
# Lock (gera somente lockfile)
###############################################################################
adm_resolve_lock() {
  local cat="$1" name="$2" out=""; shift 2 || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="$2"; shift 2;;
      *) res_warn "opção desconhecida: $1 (ignorada)"; shift;;
    esac
  done
  if ! adm_resolve_plan "$cat" "$name" >/dev/null; then
    return $?
  fi
  local p; p="$(__res_lock_path "$cat" "$name")"
  if [[ -n "$out" ]]; then
    cp -f -- "$p" "$out" 2>/dev/null || { res_err "falha ao copiar lock para $out"; return 3; }
    echo "$out"
  else
    echo "$p"
  fi
  return 0
}

###############################################################################
# CLI
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  sub="$1"; shift || true
  case "$sub" in
    plan)   adm_resolve_plan "$@" || exit $?;;
    graph)  adm_resolve_graph "$@" || exit $?;;
    check)  adm_resolve_check "$@" || exit $?;;
    lock)   adm_resolve_lock "$@" || exit $?;;
    *)
      echo "uso:" >&2
      echo "  $0 plan  <category> <name> [--version V] [--profile P] [--with-opts|--no-opts] [--bin-only|--source-only] [--offline] [--strict] [--lockfile PATH] [--update]" >&2
      echo "  $0 graph <category> <name> [--format ascii|dot]" >&2
      echo "  $0 check <category> <name> [flags do plan]" >&2
      echo "  $0 lock  <category> <name> [--out PATH]" >&2
      exit 2;;
  esac
fi

###############################################################################
# Marcar como carregado
###############################################################################
ADM_RESOLVER_LOADED=1
export ADM_RESOLVER_LOADED
