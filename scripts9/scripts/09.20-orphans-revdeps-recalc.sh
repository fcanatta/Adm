#!/usr/bin/env bash
# 09.20-orphans-revdeps-recalc.sh
# Recalcula grafo de dependências, revdeps e órfãos; gerencia "world" e relatórios.

###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__orr_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] orphans-revdeps-recalc falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __orr_err_trap ERR

###############################################################################
# Caminhos, logging, utilitários
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_ROOT}/db}"
ADM_META_DIR="${ADM_META_DIR:-${ADM_ROOT}/metafiles}"

GRAPH_DIR="${GRAPH_DIR:-${ADM_DB_DIR}/graph}"
WORLD_FILE="${WORLD_FILE:-${ADM_DB_DIR}/world.lst}"

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
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_LOG_DIR"; __ensure_dir "$ADM_TMPDIR"; __ensure_dir "$ADM_DB_DIR"; __ensure_dir "$GRAPH_DIR"

# Cores
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
orr_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
orr_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
orr_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
orr_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }
tmpfile(){ mktemp "${ADM_TMPDIR}/orr.XXXXXX"; }
trim(){
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
  | sed -E 's/[[:space:]]+/ /g'
}

# Locks
__lock(){
  local name="$1"; __ensure_dir "$ADM_STATE_DIR/locks"
  exec {__ORR_FD}>"$ADM_STATE_DIR/locks/${name}.lock"
  flock -n ${__ORR_FD} || { orr_warn "aguardando lock de ${name}…"; flock ${__ORR_FD}; }
}
__unlock(){ :; }

###############################################################################
# Hooks
###############################################################################
__hooks_dirs(){
  printf '%s\n' "${ADM_ROOT}/hooks" "${ADM_ROOT}/graph/hooks"
}
orr_hooks_run(){
  local stage="${1:?}"; shift || true
  local d f ran=0
  for d in $(__hooks_dirs); do
    [[ -d "$d" ]] || continue
    for f in "$d/$stage" "$d/$stage.sh"; do
      if [[ -x "$f" ]]; then
        orr_info "Hook: $(realpath -m "$f")"
        ( set -Eeuo pipefail; "$f" "$@" )
        ran=1
      fi
    done
  done
  (( ran )) || orr_info "Hook '${stage}': nenhum"
}

###############################################################################
# CLI
###############################################################################
CMD=""                       # scan|list-orphans|list-missing|why|dot|mark-world|unmark-world|world|suggest-prune|stats
JSON_OUT=0
LOGPATH=""
ONLY_RUNTIME=1               # considerar só run_deps por padrão (não build/opt)
FOLLOW_OPT=0                 # incluir deps opcionais
FOLLOW_BUILD=0               # incluir deps de build
ROOT="/"                     # ambiente alvo (para coerência com outros scripts)

orr_usage(){
  cat <<'EOF'
Uso:
  09.20-orphans-revdeps-recalc.sh <comando> [opções]

Comandos:
  scan                 Recalcula grafo, revdeps, órfãos e faltantes (salva em db/graph)
  list-orphans         Lista órfãos atuais (exclui "world")
  list-missing         Lista dependências faltantes (referenciadas mas não instaladas)
  why <cat/name>       Mostra cadeia(s) de quem depende do pacote (revdeps)
  dot                  Exporta grafo em DOT (stdout)
  world                Mostra world.lst
  mark-world <cat/name>     Adiciona ao world.lst
  unmark-world <cat/name>   Remove do world.lst
  suggest-prune        Sugere remoções seguras (órfãos não-world, não essenciais)
  stats                Estatísticas do grafo (nós/arestas/folhas/raízes)

Opções:
  --json               Saída JSON quando aplicável
  --log PATH           Salvar log da execução
  --root PATH          Raiz alvo (default /)
  --all-deps           Considera runtime+opt+build (padrão apenas runtime)
  --with-opt           Inclui deps opcionais
  --with-build         Inclui deps de build
  --help
EOF
}

parse_cli(){
  [[ $# -ge 1 ]] || { orr_usage; exit 2; }
  CMD="$1"; shift
  case "$CMD" in
    scan|list-orphans|list-missing|dot|world|suggest-prune|stats|why|mark-world|unmark-world) : ;;
    *) orr_err "comando inválido: $CMD"; orr_usage; exit 2 ;;
  esac
  POSITIONAL=()
  while (($#)); do
    case "$1" in
      --json) JSON_OUT=1; shift ;;
      --log) LOGPATH="${2:-}"; shift 2 ;;
      --root) ROOT="${2:-/}"; shift 2 ;;
      --all-deps) ONLY_RUNTIME=0; FOLLOW_OPT=1; FOLLOW_BUILD=1; shift ;;
      --with-opt) FOLLOW_OPT=1; shift ;;
      --with-build) FOLLOW_BUILD=1; shift ;;
      --help|-h) orr_usage; exit 0 ;;
      *) POSITIONAL+=("$1"); shift ;;
    esac
  done
}

###############################################################################
# Modelo de pacote, leitura de deps
###############################################################################
# Identificador canônico: CAT/NAME
pkg_key(){ # args: cat name
  printf '%s/%s' "$1" "$2"
}

pkg_dirs(){ # lista de dirs de pacotes instalados
  find "${ADM_DB_DIR}/installed" -mindepth 2 -maxdepth 2 -type d 2>/dev/null || true
}

# Lê deps de um pacote instalado:
# Preferência: deps.json → manifest.json → metafile plano
# Formatos esperados:
# - deps.json: {"run_deps":["a/b","c/d"], "build_deps":[...], "opt_deps":[...]}
# - manifest.json: {"deps":{"run":[...],"build":[...],"opt":[...]}} ou campos flat
# - metafile: chaves run_deps=dep1,dep2 (sem cat => assume categoria 'apps' por padrão ou 'libs' etc.)
detect_deps_for_pkg(){ # args: cat name
  local cat="$1" name="$2"
  local base="${ADM_DB_DIR}/installed/${cat}/${name}"
  local out; out="$(tmpfile)"
  echo '{"run":[],"build":[],"opt":[]}' > "$out"

  # 1) deps.json
  if [[ -r "$base/deps.json" ]] && adm_is_cmd jq; then
    local dj="$base/deps.json"
    # normaliza em /cat/name
    local tmp; tmp="$(tmpfile)"
    jq -c '{
      run:(.run_deps // .run // []) ,
      build:(.build_deps // .build // []),
      opt:(.opt_deps // .opt // [])
    }' "$dj" 2>/dev/null > "$tmp" || true
    if [[ -s "$tmp" ]]; then mv -f "$tmp" "$out"; echo "$out"; return 0; fi
  fi

  # 2) manifest.json
  if [[ -r "$base/manifest.json" ]] && adm_is_cmd jq; then
    local mj="$base/manifest.json"
    local tmp; tmp="$(tmpfile)"
    jq -c 'if .deps then
             {run:(.deps.run//[]), build:(.deps.build//[]), opt:(.deps.opt//[])}
           else
             {run:(.run_deps//[]), build:(.build_deps//[]), opt:(.opt_deps//[])}
           end' "$mj" 2>/dev/null > "$tmp" || true
    if [[ -s "$tmp" ]]; then mv -f "$tmp" "$out"; echo "$out"; return 0; fi
  fi

  # 3) metafile plano
  local mf="${ADM_META_DIR}/${cat}/${name}/metafile"
  if [[ -r "$mf" ]]; then
    local run build opt
    run="$(grep -E '^run_deps=' "$mf" 2>/dev/null | sed 's/^run_deps=//' | tr ',' ' ' | trim || true)"
    build="$(grep -E '^build_deps=' "$mf" 2>/dev/null | sed 's/^build_deps=//' | tr ',' ' ' | trim || true)"
    opt="$(grep -E '^opt_deps=' "$mf" 2>/dev/null | sed 's/^opt_deps=//' | tr ',' ' ' | trim || true)"
    {
      echo "{"
      printf '  "run": [%s],\n' "$(printf '%s\n' $run | sed -E 's#^#"#; s#$#"#' | paste -sd, -)"
      printf '  "build": [%s],\n' "$(printf '%s\n' $build | sed -E 's#^#"#; s#$#"#' | paste -sd, -)"
      printf '  "opt": [%s]\n' "$(printf '%s\n' $opt | sed -E 's#^#"#; s#$#"#' | paste -sd, -)"
      echo "}"
    } | sed 's#\[\]#[]#g' > "$out"
    echo "$out"; return 0
  fi

  echo "$out"
}

# Normaliza nomes de deps:
# Aceita formatos: "cat/name" ou apenas "name" → tenta inferir categoria (libs>apps>sys>dev)
normalize_dep_ref(){ # in: token; out: cat/name
  local tok="$1"
  [[ -z "$tok" ]] && return 1
  if [[ "$tok" == */* ]]; then
    echo "$tok"; return 0
  fi
  # inferência básica por presença no DB
  local try
  for try in libs apps sys dev; do
    if [[ -d "${ADM_DB_DIR}/installed/${try}/${tok}" ]]; then
      echo "${try}/${tok}"; return 0
    fi
  done
  # desconhecido → retorna "apps/<name>" como fallback (não instalado)
  echo "apps/${tok}"
}

###############################################################################
# Carrega universo de pacotes instalados
###############################################################################
collect_installed(){
  local out="$1"
  : > "$out"
  local d
  while IFS= read -r d; do
    local cat name; cat="$(basename "$(dirname "$d")")"; name="$(basename "$d")"
    echo "$(pkg_key "$cat" "$name")" >> "$out"
  done < <(pkg_dirs)
}

# Lê world.lst (cada linha "cat/name")
read_world(){
  local out="$1"
  : > "$out"
  [[ -r "$WORLD_FILE" ]] || { orr_warn "world.lst ausente (${WORLD_FILE}); vazio"; return 0; }
  grep -v '^\s*$' "$WORLD_FILE" | grep -v '^\s*#' | trim >> "$out" || true
}

###############################################################################
# Construção do grafo (deps e revdeps)
###############################################################################
build_graph(){
  local deps_json="$1"      # result: JSON mapa "pkg": ["depA","depB"]
  local revdeps_json="$2"   # result: JSON mapa reverso
  local missing_json="$3"   # result: JSON lista de deps referenciadas não instaladas

  adm_is_cmd jq || { orr_err "jq é necessário para construir o grafo"; exit 2; }

  local installed; installed="$(tmpfile)"; collect_installed "$installed"
  local allpkgs; allpkgs="$(tmpfile)"; sort -u "$installed" > "$allpkgs"

  # mapa deps
  local map; map="$(tmpfile)"; echo "{}" > "$map"

  while IFS= read -r pkg; do
    local cat="${pkg%%/*}" name="${pkg##*/}"
    local dj; dj="$(detect_deps_for_pkg "$cat" "$name")"
    local run build opt
    run="$(cat "$dj" | jq -r '.run[]?' 2>/dev/null || true)"
    build="$(cat "$dj" | jq -r '.build[]?' 2>/dev/null || true)"
    opt="$(cat "$dj" | jq -r '.opt[]?' 2>/dev/null || true)"

    # Seleção
    local chosen=()
    while IFS= read -r x; do [[ -n "$x" ]] && chosen+=( "$(normalize_dep_ref "$x")" ); done <<< "$run"
    if (( FOLLOW_BUILD && ONLY_RUNTIME==0 )); then while IFS= read -r x; do [[ -n "$x" ]] && chosen+=( "$(normalize_dep_ref "$x")" ); done <<< "$build"; fi
    if (( FOLLOW_OPT )); then while IFS= read -r x; do [[ -n "$x" ]] && chosen+=( "$(normalize_dep_ref "$x")" ); done <<< "$opt"; fi

    # grava
    local tmp; tmp="$(tmpfile)"
    printf '%s\n' "${chosen[@]}" | awk 'NF' | sort -u | jq -R -s 'split("\n")|map(select(length>0))' > "$tmp"
    local safe_pkg; safe_pkg="$(printf '%s' "$pkg" | sed 's#/#\\/#g')"
    jq --arg k "$pkg" --slurpfile v "$tmp" '.[$k] = $v[0]' "$map" > "${map}.n" 2>/dev/null || echo "{}" > "${map}.n"
    mv -f "${map}.n" "$map"
  done < "$allpkgs"

  # revdeps
  local rev; rev="$(tmpfile)"; echo "{}" > "$rev"
  # missing set
  local miss; miss="$(tmpfile)"; echo "[]" > "$miss"

  # transforma
  local keys; keys="$(jq -r 'keys[]' "$map")"
  while IFS= read -r src; do
    # deps do src
    local deps; deps="$(jq -r --arg k "$src" '.[$k][]?' "$map" 2>/dev/null || true)"
    while IFS= read -r dst; do
      [[ -z "$dst" ]] && continue
      # revdeps[dst] += src
      local tmp; tmp="$(tmpfile)"
      jq --arg d "$dst" --arg s "$src" '
        .[$d] = ((.[$d] // []) + [$s]) | .[$d] |= (unique)
      ' "$rev" > "$tmp" 2>/dev/null || echo "{}" > "$tmp"
      mv -f "$tmp" "$rev"
      # missing?
      if ! grep -qx -- "$dst" "$allpkgs"; then
        local t; t="$(tmpfile)"
        jq --arg m "$dst" '. += [$m] | unique' "$miss" > "$t" 2>/dev/null || echo "[]" > "$t"
        mv -f "$t" "$miss"
      fi
    done <<< "$deps"
  done <<< "$keys"

  cp -f "$map" "$deps_json"
  cp -f "$rev" "$revdeps_json"
  cp -f "$miss" "$missing_json"
}

###############################################################################
# Órfãos, folhas e raízes
###############################################################################
calc_orphans(){
  local deps_json="$1" rev_json="$2" world_list="$3" out_orphans="$4"
  adm_is_cmd jq || { orr_err "jq necessário"; exit 2; }
  local installed; installed="$(tmpfile)"; collect_installed "$installed"
  local world; world="$(tmpfile)"; read_world "$world"; [[ -s "$world" ]] || : > "$world"

  # órfão = instalado que não está no world e não tem nenhum revdep (ou só revdep dele mesmo)
  local orphans; orphans="$(tmpfile)"; : > "$orphans"
  while IFS= read -r p; do
    local has; has="$(jq -r --arg p "$p" '.[$p][]?' "$rev_json" 2>/dev/null || true)"
    local dep_count=0 self_only=1
    while IFS= read -r r; do
      [[ -z "$r" ]] && continue
      ((dep_count++))
      [[ "$r" != "$p" ]] && self_only=0 || true
    done <<< "$has"
    local is_world=0
    grep -qx -- "$p" "$world" 2>/dev/null && is_world=1
    if (( is_world==0 )) && { (( dep_count==0 )) || (( dep_count==1 && self_only==1 )); }; then
      echo "$p" >> "$orphans"
    fi
  done < <(sort -u "$installed")

  mv -f "$orphans" "$out_orphans"
}

calc_roots_leaves(){
  local deps_json="$1" rev_json="$2" out_roots="$3" out_leaves="$4"
  adm_is_cmd jq || { orr_err "jq necessário"; exit 2; }
  local keys; keys="$(jq -r 'keys[]' "$deps_json")"
  local roots; roots="$(tmpfile)"; : > "$roots"
  local leaves; leaves="$(tmpfile)"; : > "$leaves"
  while IFS= read -r p; do
    local deps; deps="$(jq -r --arg p "$p" '.[$p][]?' "$deps_json" 2>/dev/null || true)"
    local revs; revs="$(jq -r --arg p "$p" '.[$p][]?' "$rev_json" 2>/dev/null || true)"
    [[ -z "$revs" ]] && echo "$p" >> "$roots"
    [[ -z "$deps" ]] && echo "$p" >> "$leaves"
  done <<< "$keys"
  cp -f "$roots" "$out_roots"
  cp -f "$leaves" "$out_leaves"
}
###############################################################################
# Persistência (db/graph) e utilitários
###############################################################################
paths_graph(){
  echo "${GRAPH_DIR}/deps.json"
  echo "${GRAPH_DIR}/revdeps.json"
  echo "${GRAPH_DIR}/orphans.lst"
  echo "${GRAPH_DIR}/missing.json"
  echo "${GRAPH_DIR}/roots.lst"
  echo "${GRAPH_DIR}/leaves.lst"
}

graph_save(){
  local deps="$1" rev="$2" orph="$3" miss="$4" roots="$5" leaves="$6"
  __ensure_dir "$GRAPH_DIR"
  cp -f "$deps"  "${GRAPH_DIR}/deps.json"
  cp -f "$rev"   "${GRAPH_DIR}/revdeps.json"
  cp -f "$orph"  "${GRAPH_DIR}/orphans.lst"
  cp -f "$miss"  "${GRAPH_DIR}/missing.json"
  cp -f "$roots" "${GRAPH_DIR}/roots.lst"
  cp -f "$leaves" "${GRAPH_DIR}/leaves.lst"
}

graph_load_or_fail(){
  local miss=0
  for f in $(paths_graph); do
    [[ -s "$f" ]] || { orr_err "grafo não calculado: falta $f. Rode 'scan'."; miss=1; }
  done
  (( miss==0 )) || exit 4
}

###############################################################################
# Comandos
###############################################################################
cmd_scan(){
  __lock "graph-scan"
  orr_hooks_run "pre-scan" "ROOT=$ROOT"

  adm_is_cmd jq || { orr_err "jq é requerido para 'scan'"; __unlock; exit 2; }

  local deps rev miss orph roots leaves
  deps="$(tmpfile)"; rev="$(tmpfile)"; miss="$(tmpfile)"; orph="$(tmpfile)"; roots="$(tmpfile)"; leaves="$(tmpfile)"
  build_graph "$deps" "$rev" "$miss"
  calc_orphans "$deps" "$rev" "$WORLD_FILE" "$orph"
  calc_roots_leaves "$deps" "$rev" "$roots" "$leaves"
  graph_save "$deps" "$rev" "$orph" "$miss" "$roots" "$leaves"

  orr_hooks_run "post-scan" "GRAPH_DIR=$GRAPH_DIR"
  __unlock
  orr_ok "scan concluído e persistido em ${GRAPH_DIR}"
}

cmd_list_orphans(){
  graph_load_or_fail
  if (( JSON_OUT )) && adm_is_cmd jq; then
    jq -n --argfile list <(jq -R -s 'split("\n")|map(select(length>0))' "${GRAPH_DIR}/orphans.lst") '{orphans:$list}'
  else
    cat "${GRAPH_DIR}/orphans.lst"
  fi
}

cmd_list_missing(){
  graph_load_or_fail
  if (( JSON_OUT )) && adm_is_cmd jq; then
    jq '.' "${GRAPH_DIR}/missing.json" 2>/dev/null || cat "${GRAPH_DIR}/missing.json"
  else
    jq -r '.[]' "${GRAPH_DIR}/missing.json" 2>/dev/null || cat "${GRAPH_DIR}/missing.json"
  fi
}

cmd_world_show(){
  if (( JSON_OUT )) && adm_is_cmd jq; then
    jq -n --argfile list <(jq -R -s 'split("\n")|map(select(length>0))' "$WORLD_FILE" 2>/dev/null || echo '[]') '{world:$list}'
  else
    [[ -r "$WORLD_FILE" ]] && cat "$WORLD_FILE" || orr_warn "world.lst vazio"
  fi
}

__canon(){
  local ref="$1"
  if [[ "$ref" != */* ]]; then
    # tenta inferir, como normalize_dep_ref
    local x; for x in libs apps sys dev; do [[ -d "${ADM_DB_DIR}/installed/${x}/${ref}" ]] && { echo "${x}/${ref}"; return 0; }; done
    echo "apps/${ref}"
  else
    echo "$ref"
  fi
}

cmd_mark_world(){
  local ref="${POSITIONAL[0]:-}"
  [[ -n "$ref" ]] || { orr_err "mark-world requer <cat/name> ou <name>"; exit 2; }
  ref="$(__canon "$ref")"
  __ensure_dir "$(dirname "$WORLD_FILE")"
  touch "$WORLD_FILE"
  if grep -qx -- "$ref" "$WORLD_FILE" 2>/dev/null; then
    orr_info "$ref já presente no world"
  else
    echo "$ref" >> "$WORLD_FILE"
    orr_ok "adicionado ao world: $ref"
  fi
}

cmd_unmark_world(){
  local ref="${POSITIONAL[0]:-}"
  [[ -n "$ref" ]] || { orr_err "unmark-world requer <cat/name> ou <name>"; exit 2; }
  ref="$(__canon "$ref")"
  if [[ -r "$WORLD_FILE" ]]; then
    grep -vx -- "$ref" "$WORLD_FILE" > "${WORLD_FILE}.new" || true
    mv -f "${WORLD_FILE}.new" "$WORLD_FILE"
    orr_ok "removido do world: $ref"
  else
    orr_warn "world.lst inexistente"
  fi
}

cmd_why(){
  graph_load_or_fail
  local ref="${POSITIONAL[0]:-}"
  [[ -n "$ref" ]] || { orr_err "why requer <cat/name> ou <name>"; exit 2; }
  ref="$(__canon "$ref")"
  adm_is_cmd jq || { orr_err "jq requerido"; exit 2; }
  local rev="${GRAPH_DIR}/revdeps.json"
  # BFS reverso até raízes
  declare -A seen
  declare -a queue=("$ref")
  seen["$ref"]=1
  local paths; paths="$(tmpfile)"
  echo "$ref" > "$paths"

  while ((${#queue[@]})); do
    local cur="${queue[0]}"; queue=("${queue[@]:1}")
    local parents; parents="$(jq -r --arg p "$cur" '.[$p][]?' "$rev" 2>/dev/null || true)"
    [[ -z "$parents" ]] && continue
    while IFS= read -r par; do
      [[ -z "$par" ]] && continue
      if [[ -z "${seen[$par]:-}" ]]; then
        seen["$par"]=1
        queue+=("$par")
      fi
      # grava caminho par -> cur (para exibição)
      echo "$par -> $cur" >> "$paths"
    done <<< "$parents"
  done

  if (( JSON_OUT )) && adm_is_cmd jq; then
    jq -R -s 'split("\n")|map(select(length>0))' "$paths"
  else
    sort -u "$paths"
  fi
}

cmd_dot(){
  graph_load_or_fail
  adm_is_cmd jq || { orr_err "jq requerido"; exit 2; }
  local deps="${GRAPH_DIR}/deps.json"
  echo "digraph deps {"
  echo "  rankdir=LR;"
  jq -r '
    to_entries[] as $e |
    ($e.key) as $src |
    ($e.value[]?) as $dst |
    @text $src + " -> " + $dst + ";"
  ' "$deps" 2>/dev/null | sed 's/^/  "/; s/ -> /" -> "/; s/$/";/'
  echo "}"
}

cmd_stats(){
  graph_load_or_fail
  adm_is_cmd jq || { orr_err "jq requerido"; exit 2; }
  local deps="${GRAPH_DIR}/deps.json" rev="${GRAPH_DIR}/revdeps.json"
  local nodes edges roots leaves
  nodes="$(jq 'length' "$deps" 2>/dev/null || echo 0)"
  edges="$(jq '[to_entries[] | (.value|length)] | add' "$deps" 2>/dev/null || echo 0)"
  roots="$(wc -l < "${GRAPH_DIR}/roots.lst" 2>/dev/null || echo 0)"
  leaves="$(wc -l < "${GRAPH_DIR}/leaves.lst" 2>/dev/null || echo 0)"
  if (( JSON_OUT )) && adm_is_cmd jq; then
    jq -n --argjson nodes "$nodes" --argjson edges "$edges" --argjson roots "$roots" --argjson leaves "$leaves" \
      '{nodes:$nodes, edges:$edges, roots:$roots, leaves:$leaves}'
  else
    echo "nodes=$nodes edges=$edges roots=$roots leaves=$leaves"
  fi
}

###############################################################################
# Heurística de “essenciais” para não sugerir remoção
###############################################################################
is_essential(){
  local p="$1"
  case "$p" in
    sys/*|dev/toolchain|dev/gcc|dev/clang|sys/kernel*|sys/glibc|sys/musl|sys/busybox|sys/coreutils|sys/bash|sys/sh|sys/systemd|sys/openrc)
      return 0 ;;
  esac
  return 1
}

cmd_suggest_prune(){
  graph_load_or_fail
  local orf="${GRAPH_DIR}/orphans.lst"
  local out; out="$(tmpfile)"
  : > "$out"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if is_essential "$p"; then
      continue
    fi
    echo "$p" >> "$out"
  done < "$orf"
  if (( JSON_OUT )) && adm_is_cmd jq; then
    jq -n --argfile list <(jq -R -s 'split("\n")|map(select(length>0))' "$out") '{prune:$list}'
  else
    cat "$out"
  fi
}
###############################################################################
# MAIN
###############################################################################
orr_run(){
  parse_cli "$@"

  # logging opcional
  if [[ -n "$LOGPATH" ]]; then
    exec > >(tee -a "$LOGPATH") 2>&1
  fi

  case "$CMD" in
    scan)            cmd_scan ;;
    list-orphans)    cmd_list_orphans ;;
    list-missing)    cmd_list_missing ;;
    why)             cmd_why ;;
    dot)             cmd_dot ;;
    world)           cmd_world_show ;;
    mark-world)      cmd_mark_world ;;
    unmark-world)    cmd_unmark_world ;;
    suggest-prune)   cmd_suggest_prune ;;
    stats)           cmd_stats ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  orr_run "$@"
fi
