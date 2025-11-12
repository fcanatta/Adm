#!/usr/bin/env bash
# 06.10-resolve-deps-graph.sh
# Resolve dependências (run/build/opt), gera grafo, detecta ciclos e planto paralelizável.
###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__rdg_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] resolve-deps-graph falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __rdg_err_trap ERR

###############################################################################
# Caminhos, logging (fallback) e utilitários
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_META_DIR="${ADM_META_DIR:-${ADM_ROOT}/metafiles}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_REG_DIR="${ADM_REG_DIR:-${ADM_STATE_DIR}/registry}"

adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }
__ensure_dir(){
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  [[ -d "$d" ]] && return 0
  if adm_is_cmd install; then
    if [[ $EUID -ne 0 ]] && adm_is_cmd sudo; then
      sudo install -d -m "$mode" -o "$owner" -g "$group" "$d"
    else
      install -d -m "$mode" -o "$owner" -g "$group" "$d"
    fi
  else
    mkdir -p "$d"; chmod "$mode" "$d"; chown "$owner:$group" "$d" || true
  fi
}
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_TMPDIR"; __ensure_dir "$ADM_REG_DIR"

# Cores simples
if [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
rdg_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
rdg_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
rdg_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
rdg_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
tmpfile(){ mktemp "${ADM_TMPDIR}/rdg.XXXXXX"; }

trim(){ sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
split_csv(){
  # lê stdin e imprime cada item (CSV com vírgulas) em uma linha
  tr ',' '\n' | sed 's/#.*$//' | trim | sed '/^$/d'
}

###############################################################################
# Leitura do metafile + catálogo
###############################################################################
declare -A PKG_META    # chave: cat/pkg → "name|version|category|run_deps|build_deps|opt_deps"
declare -A PKG_EXISTS  # cat/pkg -> 1
declare -A NAME2CATPKG # pkg -> cat/pkg (preferência por cat igual ao root)
declare -A PROVIDERS   # virtual -> "prov1,prov2"

__canon_key(){ # (<cat>,<pkg>) → cat/pkg
  local c="$1" p="$2"
  [[ -z "$c" || "$c" == "." || "$c" == "-" ]] && c="misc"
  echo "${c}/${p}"
}
__parse_line_kv(){
  # aceita 'chave=valor' (respeita '=' no valor)
  local line="$1"
  local k="${line%%=*}" v="${line#*=}"
  k="$(echo -n "$k" | trim)"
  v="$(echo -n "$v" | trim)"
  printf '%s\001%s\n' "$k" "$v"
}
__load_providers(){
  local f="${ADM_REG_DIR}/providers.map"
  [[ -r "$f" ]] || return 0
  while IFS= read -r line; do
    line="$(echo "$line" | sed 's/#.*$//' | trim)"; [[ -z "$line" ]] && continue
    local k="${line%%=*}" v="${line#*=}"
    k="$(echo -n "$k" | trim)"; v="$(echo -n "$v" | trim)"
    PROVIDERS["$k"]="$v"
  done < "$f"
}

__index_metafiles(){
  local base="$ADM_META_DIR"
  [[ -d "$base" ]] || { rdg_warn "metafiles dir ausente: $base"; return 0; }
  local mf
  while IFS= read -r -d '' mf; do
    local dir; dir="$(dirname "$mf")"
    local cat; cat="$(basename "$(dirname "$dir")")"
    local pkg; pkg="$(basename "$dir")"
    local name version category run_deps build_deps opt_deps
    run_deps=""; build_deps=""; opt_deps=""; version=""; name="$pkg"; category="$cat"
    while IFS= read -r raw; do
      [[ -z "$raw" ]] && continue
      printf '%s\n' "$raw" | grep -q '=' || continue
      local kv; kv="$(__parse_line_kv "$raw")"
      local k="${kv%$'\001'*}" v="${kv#*$'\001'}"
      case "$k" in
        name) name="$v" ;;
        version) version="$v" ;;
        category) category="$v" ;;
        run_deps) run_deps="$v" ;;
        build_deps) build_deps="$v" ;;
        opt_deps) opt_deps="$v" ;;
      esac
    done < <(sed 's/\r$//' "$mf" | sed '/^[[:space:]]*$/d')
    local key; key="$(__canon_key "$category" "$name")"
    PKG_META["$key"]="${name}|${version}|${category}|${run_deps}|${build_deps}|${opt_deps}"
    PKG_EXISTS["$key"]=1
    # índice rápido por nome simples (se ambíguo, mantém o primeiro)
    [[ -z "${NAME2CATPKG[$name]:-}" ]] && NAME2CATPKG["$name"]="$key" || true
  done < <(find "$base" -type f -name 'metafile' -print0)
}

###############################################################################
# Normalização de referências de pacote e seleção de provider
###############################################################################
# Sintaxes aceitas:
#   - "categoria/pacote"
#   - "pacote"
#   - "virtual" (se existir em providers.map)
#   - restrições: "pacote>=1.2.3", "libfoo=2.0", etc.
__parse_req(){
  # entrada: string de requisito → "name|op|ver"
  local s="$(echo -n "$1" | trim)"
  local name op ver
  if [[ "$s" =~ (.*)([<>=]{1,2})([^<>=]+)$ ]]; then
    name="$(echo -n "${BASH_REMATCH[1]}" | trim)"
    op="${BASH_REMATCH[2]}"
    ver="$(echo -n "${BASH_REMATCH[3]}" | trim)"
  else
    name="$s"; op=""; ver=""
  fi
  printf '%s|%s|%s\n' "$name" "$op" "$ver"
}

__maybe_pick_provider(){
  # entrada: "name" → retorna cat/pkg de um provider se for virtual, ou vazio
  local name="$1"
  local provlist="${PROVIDERS[$name]:-}"
  [[ -z "$provlist" ]] && { echo ""; return 0; }
  # heurística simples: pega o primeiro provider existente nos metafiles
  local item
  for item in $(echo "$provlist" | split_csv); do
    local key="${NAME2CATPKG[$item]:-}"
    [[ -n "$key" && -n "${PKG_EXISTS[$key]:-}" ]] && { echo "$key"; return 0; }
  done
  echo ""
}

__resolve_pkg_ref(){
  # entrada: "cat/pkg" ou "pkg" ou virtual → retorna "cat/pkg" (ou vazio se não encontrado)
  local token="$1"
  if [[ "$token" == */* ]]; then
    # já tem categoria
    local key="$token"
    [[ -n "${PKG_EXISTS[$key]:-}" ]] && { echo "$key"; return 0; }
    echo ""; return 0
  fi
  # nome simples: tenta mapeamento direto
  local key="${NAME2CATPKG[$token]:-}"
  if [[ -n "$key" ]]; then echo "$key"; return 0; fi
  # virtual via providers
  key="$(__maybe_pick_provider "$token")"
  [[ -n "$key" ]] && { echo "$key"; return 0; }
  echo ""
}

###############################################################################
# Comparação de versões simples
###############################################################################
__ver_cmp(){
  # retorna -1 se a<b, 0 se a==b, 1 se a>b ; comparação semântica simplificada (num/alpha)
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && { echo 0; return; }
  # divide por '.', '-', '_' e compara segmento a segmento
  local IFS='._-'
  read -r -a A <<< "$a"
  read -r -a B <<< "$b"
  local n=$(( ${#A[@]} > ${#B[@]} ? ${#A[@]} : ${#B[@]} ))
  for ((i=0;i<n;i++)); do
    local x="${A[i]:-0}" y="${B[i]:-0}"
    if [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]]; then
      ((10#$x < 10#$y)) && { echo -1; return; }
      ((10#$x > 10#$y)) && { echo 1; return; }
    else
      [[ "$x" < "$y" ]] && { echo -1; return; }
      [[ "$x" > "$y" ]] && { echo 1; return; }
    fi
  done
  echo 0
}
__ver_satisfies(){
  local cur="$1" op="$2" want="$3"
  [[ -z "$op" ]] && { echo 1; return; }
  local cmp; cmp="$(__ver_cmp "$cur" "$want")"
  case "$op" in
    "=")  [[ "$cmp" -eq 0 ]] && echo 1 || echo 0 ;;
    "==") [[ "$cmp" -eq 0 ]] && echo 1 || echo 0 ;;
    ">")  [[ "$cmp" -gt 0 ]] && echo 1 || echo 0 ;;
    ">=") [[ "$cmp" -ge 0 ]] && echo 1 || echo 0 ;;
    "<")  [[ "$cmp" -lt 0 ]] && echo 1 || echo 0 ;;
    "<=") [[ "$cmp" -le 0 ]] && echo 1 || echo 0 ;;
    *) echo 0 ;;
  esac
}

###############################################################################
# Construção do grafo
###############################################################################
# Estruturas:
#   NODES: array de nós (cat/pkg)
#   EDGE_<from>: set (string com espaços) dos destinos
#   ATTR_<node>="name|version|category"
#   REQ_<node>_RUN="dep1 dep2 ..."   (cada dep é cat/pkg)
#   REQ_<node>_BLD="..."
#   REQ_<node>_OPT="..."

declare -a NODES=()
declare -A VISITED NODE_SET
declare -A ATTR
declare -A EDGE RUNDEPS BLDDEPS OPTDEPS

__attrs_for_key(){
  local key="$1" meta="${PKG_META[$key]}"
  IFS='|' read -r name version category run build opt <<< "$meta"
  printf '%s|%s|%s\n' "$name" "$version" "$category"
}
__emit_req_list(){
  # entrada: CSV de deps; saída: lista de "cat/pkg" válidos
  local csv="$1"
  local out=()
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    local parsed="$(__parse_req "$d")"
    local nm="${parsed%%|*}"; local rest="${parsed#*|}"
    local op="${rest%%|*}"; local ver="${rest#*|}"
    local key; key="$(__resolve_pkg_ref "$nm")"
    if [[ -z "$key" ]]; then
      rdg_warn "dependência '${nm}' não encontrada (ignorando por ora)"
      continue
    fi
    # versão
    local curver; curver="$(echo "${PKG_META[$key]}" | awk -F'|' '{print $2}')"
    if [[ -n "$op" && -n "$ver" ]]; then
      if [[ "$(__ver_satisfies "$curver" "$op" "$ver")" != "1" ]]; then
        rdg_warn "versão de '${key}' (${curver}) não satisfaz ${op}${ver}"
      fi
    end
    out+=("$key")
  done < <(echo "$csv" | split_csv)
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++'
}

__add_node(){
  local key="$1"
  [[ -n "${NODE_SET[$key]:-}" ]] && return 0
  NODE_SET["$key"]=1
  NODES+=("$key")
  ATTR["$key"]="$(__attrs_for_key "$key")"
  # popula listas de deps por tipo
  local meta="${PKG_META[$key]}"
  IFS='|' read -r name version category run build opt <<< "$meta"
  RUNDEPS["$key"]="$(__emit_req_list "${run:-}")"
  BLDDEPS["$key"]="$(__emit_req_list "${build:-}")"
  OPTDEPS["$key"]="$(__emit_req_list "${opt:-}")"
}

__dfs_collect(){
  # uso: __dfs_collect <key> <target> <include_opt> <depth_left>
  local key="$1" target="$2" withopt="$3" depth="$4"
  (( depth < 0 )) && return 0
  __add_node "$key"
  local deps=()
  [[ "$target" == "run"  || "$target" == "all" ]] && deps+=( ${RUNDEPS[$key]:-} )
  [[ "$target" == "build"|| "$target" == "all" ]] && deps+=( ${BLDDEPS[$key]:-} )
  (( withopt )) && deps+=( ${OPTDEPS[$key]:-} )
  local d
  for d in "${deps[@]:-}"; do
    __add_node "$d"
    EDGE["$key"]="${EDGE[$key]:-} $d"
    __dfs_collect "$d" "$target" "$withopt" "$((depth-1))"
  done
}

###############################################################################
# Ciclos e ordenação topológica (Kahn + DFS para diagnóstico)
###############################################################################
topo_sort(){
  # saída: ordem linear (nós) e "waves" (níveis)
  local -A indeg=()
  local n from to
  for n in "${NODES[@]}"; do indeg["$n"]=0; done
  for from in "${NODES[@]}"; do
    for to in ${EDGE[$from]:-}; do
      (( indeg["$to"]++ ))
    done
  done
  local -a q=() order=() ; local -a wave=() ; local curwave=()
  for n in "${NODES[@]}"; do (( indeg["$n"]==0 )) && q+=( "$n" ); done
  # waves
  while ((${#q[@]}>0)); do
    curwave=( "${q[@]}" ); q=()
    wave+=( "$(printf '%s ' "${curwave[@]}" | sed 's/[ ]$//')" )
    local v
    for v in "${curwave[@]}"; do
      order+=( "$v" )
      for to in ${EDGE[$v]:-}; do
        (( --indeg["$to"] ))
        (( indeg["$to"]==0 )) && q+=( "$to" )
      done
    done
  done
  # checar ciclos
  if ((${#order[@]} != ${#NODES[@]})); then
    rdg_warn "grafo possui ciclo(s); tentando diagnóstico por DFS…"
    cycle_report
    return 1
  fi
  # exporta globais
  TOPO_ORDER=( "${order[@]}" )
  WAVES=( "${wave[@]}" )
  return 0
}

cycle_report(){
  # DFS com pilha para encontrar pelo menos um ciclo
  local -A color=() parent=()
  for n in "${NODES[@]}"; do color["$n"]=0; done  # 0=white,1=gray,2=black
  local stack=()
  __dfs(){
    local u="$1"; color["$u"]=1; stack+=( "$u" )
    local v
    for v in ${EDGE[$u]:-}; do
      if (( color["$v"]==0 )); then
        parent["$v"]="$u"; __dfs "$v" && return 0
      elif (( color["$v"]==1 )); then
        # ciclo encontrado: reconstrói
        local cyc=( "$v" )
        local x="$u"
        while [[ "$x" != "$v" && -n "$x" ]]; do cyc=( "$x" "${cyc[@]}" ); x="${parent[$x]:-}"; done
        echo -e "${C_ERR}[CICLO]${C_RST} $(printf '%s -> ' "${cyc[@]}")${v}"
        return 0
      fi
    done
    color["$u"]=2; unset 'stack[${#stack[@]}-1]'
    return 1
  }
  local s; for s in "${NODES[@]}"; do
    (( color["$s"]==0 )) && __dfs "$s" && break || true
  done
}

###############################################################################
# Saídas: JSON / DOT / Texto
###############################################################################
json_escape(){ local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; printf '%s' "$s"; }

emit_json(){
  local out="$1"
  local tmp; tmp="$(tmpfile)"
  {
    echo "{"
    echo '  "nodes": {'
    local n first=1
    for n in "${NODES[@]}"; do
      ((first)) || echo ','
      local attr="${ATTR[$n]}"; IFS='|' read -r nm ver cat <<< "$attr"
      printf '    "%s": {"name":"%s","version":"%s","category":"%s"}' "$(json_escape "$n")" "$(json_escape "$nm")" "$(json_escape "$ver")" "$(json_escape "$cat")"
      first=0
    done
    echo -e "\n  },"
    echo '  "edges": ['
    local from to sep=""
    for from in "${NODES[@]}"; do
      for to in ${EDGE[$from]:-}; do
        printf '%s    {"from":"%s","to":"%s"}' "$sep" "$(json_escape "$from")" "$(json_escape "$to")"
        sep=$',\n'
      done
    done
    echo -e "\n  ],"
    echo '  "plan": {'
    echo '    "topological_order": ['
    local i sep=""
    for i in "${TOPO_ORDER[@]:-}"; do
      printf '%s      "%s"' "$sep" "$(json_escape "$i")"; sep=$',\n'
    done
    echo -e "\n    ],"
    echo '    "waves": ['
    local w s=""
    for w in "${WAVES[@]:-}"; do
      printf '%s      ["%s"]' "$s" "$(json_escape "$w" | sed 's/ /","/g')"
      s=$',\n'
    done
    echo -e "\n    ]"
    echo "  }"
    echo "}"
  } > "$tmp"
  if adm_is_cmd jq; then jq . "$tmp" > "$out" 2>/dev/null || cp -f "$tmp" "$out"; else cp -f "$tmp" "$out"; fi
  rdg_ok "JSON salvo: $out"
}

emit_dot(){
  local out="$1"
  {
    echo "digraph deps {"
    echo "  rankdir=LR;"
    echo "  node [shape=box, style=rounded];"
    local n attr nm ver cat
    for n in "${NODES[@]}"; do
      attr="${ATTR[$n]}"; IFS='|' read -r nm ver cat <<< "$attr"
      echo "  \"${n}\" [label=\"${n}\\n${ver}\"];"
    done
    local from to
    for from in "${NODES[@]}"; do
      for to in ${EDGE[$from]:-}; do
        echo "  \"${from}\" -> \"${to}\";"
      done
    done
    echo "}"
  } > "$out"
  rdg_ok "DOT salvo: $out"
}

emit_text(){
  # plano linear e waves
  echo -e "${C_BD}== Ordem topológica ==${C_RST}"
  printf '  %s\n' "${TOPO_ORDER[@]:-/?}"
  echo -e "${C_BD}== Waves (paralelizáveis) ==${C_RST}"
  local i=1 w; for w in "${WAVES[@]:-}"; do
    echo "  wave $i: $w"; ((i++))
  done
}
###############################################################################
# CLI e orquestração
###############################################################################
RDG_ROOT=""     # cat/pkg ou pkg
RDG_TARGET="all"          # run|build|all
RDG_INCLUDE_OPT=0         # 1 inclui opt_deps
RDG_MAX_DEPTH=9999
RDG_FORMAT="text"         # text|json|dot|all
RDG_OUTDIR=""             # default: ${ADM_STATE_DIR}/deps/<cat>/<pkg>
RDG_REVERSE=0             # inverte arestas (para grafo de rdeps)
RDG_STRICT_PROVIDER=0     # falha se virtual sem provider

rdg_usage(){
  cat <<'EOF'
Uso:
  06.10-resolve-deps-graph.sh --root <cat/pkg|pkg> [opções]

Opções:
  --target {run|build|all}      Tipos de deps a considerar (default: all)
  --include-optional            Inclui opt_deps
  --max-depth N                 Limite de profundidade (default: ilimitado)
  --format {text|json|dot|all}  Saída desejada (default: text)
  --outdir DIR                  Onde salvar JSON/DOT/plan (default automático)
  --reverse                     Mostra grafo de dependentes (rdeps)
  --strict-provider             Erro se virtual sem provider resolvido
  --help                        Esta ajuda
EOF
}

parse_cli(){
  while (($#)); do
    case "$1" in
      --root) RDG_ROOT="${2:-}"; shift 2 ;;
      --target) RDG_TARGET="${2:-all}"; shift 2 ;;
      --include-optional) RDG_INCLUDE_OPT=1; shift ;;
      --max-depth) RDG_MAX_DEPTH="${2:-9999}"; shift 2 ;;
      --format) RDG_FORMAT="${2:-text}"; shift 2 ;;
      --outdir) RDG_OUTDIR="${2:-}"; shift 2 ;;
      --reverse) RDG_REVERSE=1; shift ;;
      --strict-provider) RDG_STRICT_PROVIDER=1; shift ;;
      --help|-h) rdg_usage; exit 0 ;;
      *) rdg_err "opção inválida: $1"; rdg_usage; exit 2 ;;
    esac
  done
  if [[ -z "$RDG_ROOT" ]]; then
    # fallback ao pacote corrente via ADM_META
    local cat="${ADM_META[category]:-}" name="${ADM_META[name]:-}"
    [[ -n "$cat" && -n "$name" ]] && RDG_ROOT="${cat}/${name}" || { rdg_err "falta --root"; exit 3; }
  fi
  case "$RDG_TARGET" in run|build|all) : ;; *) rdg_err "--target inválido"; exit 2;; esac
  case "$RDG_FORMAT" in text|json|dot|all) : ;; *) rdg_err "--format inválido"; exit 2;; esac
}

###############################################################################
# Reverse graph (rdeps)
###############################################################################
build_reverse_edges(){
  local -A rev=()
  local from to
  for from in "${NODES[@]}"; do
    for to in ${EDGE[$from]:-}; do
      rev["$to"]="${rev[$to]:-} $from"
    done
  done
  # reescreve EDGE como reverso e reordena NODES para manter estabilidade
  for from in "${NODES[@]}"; do EDGE["$from"]="${rev[$from]:-}"; done
}

###############################################################################
# Save artifacts helpers
###############################################################################
__output_paths_for(){
  local key="$1"
  local cat="${key%%/*}" pkg="${key#*/}"
  local out="${RDG_OUTDIR:-${ADM_STATE_DIR}/deps/${cat}/${pkg}}"
  __ensure_dir "$out"
  echo "$out"
}

###############################################################################
# MAIN
###############################################################################
rdg_run(){
  parse_cli "$@"

  __load_providers
  __index_metafiles

  # resolve root
  local root_key; root_key="$(__resolve_pkg_ref "$RDG_ROOT")"
  if [[ -z "$root_key" ]]; then
    if (( RDG_STRICT_PROVIDER )); then
      rdg_err "pacote/virtual '${RDG_ROOT}' não foi resolvido (strict-provider)"
      exit 10
    else
      rdg_warn "root '${RDG_ROOT}' não encontrado; tentando como nome literal…"
      root_key="$RDG_ROOT"
    fi
  fi

  # coleta transitiva
  __dfs_collect "$root_key" "$RDG_TARGET" "$RDG_INCLUDE_OPT" "$RDG_MAX_DEPTH"

  # grafo reverso se solicitado
  (( RDG_REVERSE )) && build_reverse_edges

  # topológica / waves
  if ! topo_sort; then
    rdg_err "não foi possível produzir ordem topológica (ciclos presentes)"
    exit 20
  fi

  # persistir artefatos
  local outdir; outdir="$(__output_paths_for "$root_key")"
  local json="$outdir/graph.json" dot="$outdir/graph.dot" plan="$outdir/plan.json"

  # plano em JSON simples
  {
    echo '{'
    echo '  "order": ['
    local sep="" n; for n in "${TOPO_ORDER[@]}"; do printf '%s    "%s"' "$sep" "$n"; sep=$',\n'; done
    echo -e '\n  ],'
    echo '  "waves": ['
    local s="" w; for w in "${WAVES[@]}"; do printf '%s    ["%s"]' "$s" "$(echo "$w" | sed 's/ /","/g')"; s=$',\n'; done
    echo -e '\n  ]'
    echo '}'
  } > "$plan"

  # emitir formatos
  case "$RDG_FORMAT" in
    text) emit_text ;;
    json) emit_json "$json" ;;
    dot)  emit_dot  "$dot"  ;;
    all)  emit_text; emit_json "$json"; emit_dot "$dot" ;;
  esac

  rdg_ok "Artefatos: $(realpath -m "$outdir")"
}

###############################################################################
# Execução direta
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  rdg_run "$@"
fi
