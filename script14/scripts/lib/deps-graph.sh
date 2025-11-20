#!/usr/bin/env bash
# shellcheck shell=bash
#
# Grafo de dependências simples armazenado em meta/deps-graph.tsv
# Formato: pacote<TAB>dep1,dep2,...

set -Eeuo pipefail

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "/usr/src/adm/scripts/lib/common.sh"

ADM_DEPS_GRAPH_FILE="${ADM_DEPS_GRAPH_FILE:-/usr/src/adm/meta/deps-graph.tsv}"

adm_deps_init() {
  adm_mkdir_safe "$(dirname "$ADM_DEPS_GRAPH_FILE")"
  [[ -e "$ADM_DEPS_GRAPH_FILE" ]] || : >"$ADM_DEPS_GRAPH_FILE"
}

adm_deps_set() {
  local pkg="$1"
  local deps_csv="$2"

  adm_deps_init

  # remove linha antiga
  grep -v -E "^${pkg}[[:space:]]" "$ADM_DEPS_GRAPH_FILE" >"$ADM_DEPS_GRAPH_FILE.tmp" || true
  printf '%s\t%s\n' "$pkg" "$deps_csv" >>"$ADM_DEPS_GRAPH_FILE.tmp"
  mv "$ADM_DEPS_GRAPH_FILE.tmp" "$ADM_DEPS_GRAPH_FILE"
}

adm_deps_get() {
  local pkg="$1"
  [[ -r "$ADM_DEPS_GRAPH_FILE" ]] || return 1
  awk -F'\t' -v p="$pkg" '$1 == p { print $2 }' "$ADM_DEPS_GRAPH_FILE"
}

# Ordenação topológica simplificada (sem checar ciclos a fundo)
adm_deps_toposort() {
  adm_deps_init
  python3 - <<'PY'
import sys

graph = {}
order = []

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            pkg, deps = line.split("\t", 1)
            deps_list = [d.strip() for d in deps.split(",") if d.strip()]
            graph[pkg] = deps_list
except FileNotFoundError:
    sys.exit(0)

temp_mark = set()
perm_mark = set()

def visit(node):
    if node in perm_mark:
        return
    if node in temp_mark:
        raise RuntimeError(f"Ciclo detectado em dependências (pacote: {node})")
    temp_mark.add(node)
    for dep in graph.get(node, []):
        visit(dep)
    temp_mark.remove(node)
    perm_mark.add(node)
    order.append(node)

for n in list(graph.keys()):
    if n not in perm_mark:
        visit(n)

for n in order:
    print(n)
PY "$ADM_DEPS_GRAPH_FILE"
}
