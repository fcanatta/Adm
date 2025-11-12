#!/usr/bin/env bash
# 10.20-bulk-update-planner.sh
# Planeja e opcionalmente aplica atualizações em lote usando 10.10-update-upstream-tracker.sh.

###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__bp_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] bulk-update-planner falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __bp_err_trap ERR

###############################################################################
# Caminhos, logging, utilitários
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_ROOT}/db}"
ADM_META_DIR="${ADM_META_DIR:-${ADM_ROOT}/metafiles}"
UPDATE_DIR="${UPDATE_DIR:-${ADM_ROOT}/update}"
GRAPH_DIR="${GRAPH_DIR:-${ADM_DB_DIR}/graph}"

TRACKER="${TRACKER:-${ADM_ROOT}/scripts/10.10-update-upstream-tracker.sh}"
ORDER_SCRIPT="${ORDER_SCRIPT:-${ADM_ROOT}/scripts/06.20-order-toposort-strategy.sh}"

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
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_LOG_DIR"; __ensure_dir "$ADM_TMPDIR"; __ensure_dir "$ADM_DB_DIR"; __ensure_dir "$UPDATE_DIR"

# Cores
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
bp_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
bp_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
bp_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
bp_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }
tmpfile(){ mktemp "${ADM_TMPDIR}/bp.XXXXXX"; }
now_ts(){ date -u +%Y%m%d-%H%M%S; }

# Locks
__lock(){
  local name="$1"; __ensure_dir "$ADM_STATE_DIR/locks"
  exec {__BP_FD}>"$ADM_STATE_DIR/locks/${name}.lock"
  flock -n ${__BP_FD} || { bp_warn "aguardando lock de ${name}…"; flock ${__BP_FD}; }
}
__unlock(){ :; }

###############################################################################
# Hooks
###############################################################################
__hooks_dirs(){
  printf '%s\n' "${ADM_ROOT}/hooks" "${ADM_ROOT}/update/hooks"
}
bp_hooks_run(){
  local stage="${1:?}"; shift || true
  local d f ran=0
  for d in $(__hooks_dirs); do
    [[ -d "$d" ]] || continue
    for f in "$d/$stage" "$d/$stage.sh"; do
      if [[ -x "$f" ]]; then
        bp_info "Hook: $(realpath -m "$f")"
        ( set -Eeuo pipefail; "$f" "$@" )
        ran=1
      fi
    done
  done
  (( ran )) || bp_info "Hook '${stage}': nenhum"
}

###############################################################################
# CLI
###############################################################################
JSON_OUT=0
LOGPATH=""
DRYRUN=0

SCOPE="installed"            # installed|metafiles|list
CATEGORIES=""                # CSV (ex.: libs,apps)
NAME=""                      # um pacote específico (cat+name requeridos juntos se usado)
LIST_FILE=""                 # arquivo com linhas cat/name
EXCLUDE=""                   # CSV de padrões a excluir (glob simples)
ONLY_NEW=1                   # manter só pacotes com nova versão

# opções pass-through para o tracker 10.10
PROVIDER="auto"
REGEX=""
PRERELEASE=0
TAG_PREFIX=""
DOWNLOAD=0
VERIFY_SIG=0
PARALLEL_TRACKER="${PARALLEL_TRACKER:-4}"
PARALLEL_DOWNLOADS=""        # se setado, passa --parallel ao tracker
APPLY=0
OUT_DIR=""                  # base para updates
WITH_JSON_FROM_TRACKER=1

# ordering
ORDER_BY_GRAPH=1             # usar deps.json se disponível
FALLBACK_LEX=1               # se não houver grafo, ordenar alfabeticamente
RESPECT_WORLD=0              # se 1, mantém world primeiro (não remove; apenas ordena antes)
WORLD_FILE="${WORLD_FILE:-${ADM_DB_DIR}/world.lst}"

bp_usage(){
  cat <<'EOF'
Uso:
  10.20-bulk-update-planner.sh [opções]

Escopo de seleção:
  --scope installed|metafiles|list   (default: installed)
  --categories CSV                   (filtra por categorias)
  --name NAME                        (junto de --categories se alvo único)
  --list-file PATH                   (linhas "cat/name")
  --exclude CSV                      (padrões glob para excluir)
  --all                              Não filtra somente "novos" (inclui noops)

Orquestração/execução:
  --parallel N                       Paralelismo de rastreios (default 4)
  --download                         Repasse ao tracker: baixa fontes & sha256
  --verify-sig                       Repasse ao tracker: tenta verificar assinaturas
  --provider auto|github|gitlab|...  Provider preferido (repasse)
  --regex REGEX                      Regex para versões estáveis (repasse)
  --include-prerelease               Permite pré-releases (repasse)
  --tag-prefix STR                   Prefixo de tag a remover (repasse)
  --dl-parallel N                    Paralelismo interno de downloads do tracker
  --apply                            Escreve metafiles de update
  --out-dir DIR                      Base para outputs (default update/CAT/NAME)
  --no-json-from-tracker             Não espera JSON do tracker (modo legado)

Ordenação:
  --no-graph-order                   Não usa deps.json (ordem alfabética)
  --respect-world                    (apenas ordem) prioriza pacotes do world.lst

Outros:
  --json                             Saída JSON agregada
  --dry-run                          Simula (não escreve/metafile)
  --log PATH                         Salvar log desta execução
  --help
EOF
}

parse_cli(){
  while (($#)); do
    case "$1" in
      --scope) SCOPE="${2:-installed}"; shift 2 ;;
      --categories) CATEGORIES="${2:-}"; shift 2 ;;
      --name) NAME="${2:-}"; shift 2 ;;
      --list-file) LIST_FILE="${2:-}"; shift 2 ;;
      --exclude) EXCLUDE="${2:-}"; shift 2 ;;
      --all) ONLY_NEW=0; shift ;;
      --parallel) PARALLEL_TRACKER="${2:-4}"; shift 2 ;;
      --download) DOWNLOAD=1; shift ;;
      --verify-sig) VERIFY_SIG=1; shift ;;
      --provider) PROVIDER="${2:-auto}"; shift 2 ;;
      --regex) REGEX="${2:-}"; shift 2 ;;
      --include-prerelease) PRERELEASE=1; shift ;;
      --tag-prefix) TAG_PREFIX="${2:-}"; shift 2 ;;
      --dl-parallel) PARALLEL_DOWNLOADS="${2:-}"; shift 2 ;;
      --apply) APPLY=1; shift ;;
      --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
      --no-json-from-tracker) WITH_JSON_FROM_TRACKER=0; shift ;;
      --no-graph-order) ORDER_BY_GRAPH=0; shift ;;
      --respect-world) RESPECT_WORLD=1; shift ;;
      --json) JSON_OUT=1; shift ;;
      --dry-run) DRYRUN=1; shift ;;
      --log) LOGPATH="${2:-}"; shift 2 ;;
      --help|-h) bp_usage; exit 0 ;;
      *) bp_err "opção inválida: $1"; bp_usage; exit 2 ;;
    esac
  done
  # valida escopo
  case "$SCOPE" in installed|metafiles|list) : ;; *) bp_err "scope inválido"; exit 2 ;; esac
  # alvo único coerente?
  if [[ -n "$NAME" && -z "$CATEGORIES" ]]; then
    bp_err "--name requer também --categories (cat única)"; exit 2
  fi
  if [[ ! -x "$TRACKER" ]]; then
    bp_err "tracker não encontrado/executável: $TRACKER"; exit 3
  fi
}

###############################################################################
# Seleção de pacotes (cat/name)
###############################################################################
__csv_to_arr(){ local IFS=','; read -r -a __arr <<< "$1"; printf '%s\n' "${__arr[@]}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | sed '/^$/d'; }
__filter_by_categories(){
  local in="$1" out="$2"
  : > "$out"
  if [[ -z "$CATEGORIES" ]]; then
    cat "$in" > "$out"; return 0
  fi
  local -a cats; mapfile -t cats < <(__csv_to_arr "$CATEGORIES")
  while IFS= read -r line; do
    for c in "${cats[@]}"; do
      [[ "$line" == "$c"/* ]] && { echo "$line" >> "$out"; break; }
    done
  done < "$in"
}
__apply_exclude(){
  local in="$1" out="$2"
  : > "$out"
  if [[ -z "$EXCLUDE" ]]; then cat "$in" > "$out"; return 0; fi
  local -a pats; mapfile -t pats < <(__csv_to_arr "$EXCLUDE")
  while IFS= read -r line; do
    local skip=0 p
    for p in "${pats[@]}"; do
      [[ "$line" == $p ]] && { skip=1; break; }
    done
    (( skip )) || echo "$line" >> "$out"
  done < "$in"
}

collect_scope(){
  local out="$1"
  : > "$out"
  case "$SCOPE" in
    installed)
      find "${ADM_DB_DIR}/installed" -mindepth 2 -maxdepth 2 -type d -printf '%P\n' 2>/dev/null \
        | sed -E 's#^#/#' | sed 's#^/##' | sed 's#/#/#' > "$out" || true
      ;;
    metafiles)
      find "${ADM_META_DIR}" -mindepth 2 -maxdepth 2 -type f -name 'metafile' -printf '%P\n' 2>/dev/null \
        | sed -E 's#/metafile$##' > "$out" || true
      ;;
    list)
      [[ -r "$LIST_FILE" ]] || { bp_err "--list-file requerido para scope=list"; exit 2; }
      grep -v '^\s*$' "$LIST_FILE" | grep -v '^\s*#' > "$out" || true
      ;;
  esac
  # alvo único
  if [[ -n "$NAME" && -n "$CATEGORIES" ]]; then
    : > "$out"; echo "${CATEGORIES}/${NAME}" >> "$out"
  fi
}

###############################################################################
# Execução do tracker para cada pacote
###############################################################################
build_tracker_cmd(){
  local ref="$1" category="${ref%%/*}" name="${ref##*/}"
  local args=( "--category" "$category" "--name" "$name" "--provider" "$PROVIDER" )
  (( PRERELEASE )) && args+=( "--include-prerelease" )
  [[ -n "$REGEX" ]] && args+=( "--regex" "$REGEX" )
  [[ -n "$TAG_PREFIX" ]] && args+=( "--tag-prefix" "$TAG_PREFIX" )
  (( DOWNLOAD )) && args+=( "--download" )
  (( VERIFY_SIG )) && args+=( "--verify-sig" )
  [[ -n "$OUT_DIR" ]] && args+=( "--out-dir" "$OUT_DIR" )
  (( APPLY )) && args+=( "--apply" )
  if (( WITH_JSON_FROM_TRACKER )); then args+=( "--json" ); fi
  if [[ -n "$PARALLEL_DOWNLOADS" ]]; then args+=( "--parallel" "$PARALLEL_DOWNLOADS" ); fi
  printf '%q ' "$TRACKER" "${args[@]}"
}

run_trackers_parallel(){
  local refs_file="$1" out_dir="$2" plan_tmp="$3"
  __ensure_dir "$out_dir"
  : > "$plan_tmp"

  local -a pids=()
  local -i running=0
  local max="$PARALLEL_TRACKER"

  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    local one_log="${out_dir}/${ref//\//_}.log"
    local one_json="${out_dir}/${ref//\//_}.json"
    (
      set -Eeuo pipefail
      local cmd; cmd="$(build_tracker_cmd "$ref")"
      if (( DRYRUN )); then
        echo "(dry-run) ${cmd}" | tee "$one_log" >/dev/null
        # json sintético
        echo "{\"category\":\"${ref%%/*}\",\"name\":\"${ref##*/}\",\"status\":\"noop\",\"reason\":\"dry-run\"}" > "$one_json"
      else
        # executa e captura
        if (( WITH_JSON_FROM_TRACKER )); then
          eval "${cmd}" > "$one_json" 2> "$one_log" || true
        else
          eval "${cmd}" > "$one_log" 2>&1 || true
          # gera JSON mínimo lendo última linha "Nova versão..." do log (best-effort)
          if grep -q "Nova versão encontrada" "$one_log"; then
            local nv; nv="$(sed -nE 's/.*Nova versão encontrada: ([^ ]+).*/\1/p' "$one_log" | tail -n1 || true)"
            echo "{\"category\":\"${ref%%/*}\",\"name\":\"${ref##*/}\",\"new\":\"$nv\",\"status\":\"ok\"}" > "$one_json"
          else
            echo "{\"category\":\"${ref%%/*}\",\"name\":\"${ref##*/}\",\"status\":\"noop\"}" > "$one_json"
          fi
        fi
      fi
      echo "$one_json"
    ) &
    pids+=( $! )
    ((running++))
    if (( running >= max )); then
      wait -n || true
      ((running--))
    fi
  done < "$refs_file"

  # aguarda todos
  wait || true

  # consolida JSONs listados
  for j in "$out_dir"/*.json; do
    [[ -s "$j" ]] || continue
    cat "$j" >> "$plan_tmp"
  done
}
###############################################################################
# Ordenação e plano final
###############################################################################
jq_or_cat_array(){
  # compacta várias linhas JSON em um array JSON
  if adm_is_cmd jq; then
    jq -s '.' 2>/dev/null || cat
  else
    # sem jq, embrulha toscamente
    awk 'BEGIN{print "["}{if(NR>1)printf ","; printf "%s",$0}END{print "]"}'
  fi
}

read_graph_deps(){
  local deps="${GRAPH_DIR}/deps.json"
  [[ -r "$deps" ]] || { echo "{}"; return 1; }
  cat "$deps"
}

toposort_with_graph(){
  # args: refs_file -> ordered_file
  local in="$1" out="$2"
  : > "$out"
  adm_is_cmd jq || { bp_warn "jq ausente; não dá pra ordenar por grafo"; return 1; }

  local deps_json; deps_json="$(read_graph_deps)" || { return 1; }

  # Coleção de alvos
  local targets; targets="$(tmpfile)"
  sort -u "$in" > "$targets"

  # Mapeia cat/name -> deps filtrando só alvos presentes
  local map; map="$(tmpfile)"
  echo "{}" > "$map"
  while IFS= read -r ref; do
    local deps; deps="$(jq -r --arg k "$ref" '.[$k][]?' <<< "$deps_json" 2>/dev/null || true)"
    # mantém só deps que também estão nos targets (update em cascata)
    local keep=()
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      grep -qx -- "$d" "$targets" 2>/dev/null && keep+=( "$d" ) || true
    done <<< "$deps"
    local tmp; tmp="$(tmpfile)"
    printf '%s\n' "${keep[@]}" | jq -R -s 'split("\n")|map(select(length>0))' > "$tmp"
    jq --arg k "$ref" --slurpfile v "$tmp" '.[$k] = $v[0]' "$map" > "${map}.n" 2>/dev/null || echo "{}" > "${map}.n"
    mv -f "${map}.n" "$map"
  done < "$targets"

  # Kahn
  local indeg; indeg="$(tmpfile)"; : > "$indeg"
  jq -r 'to_entries[] | "\(.key)\t\(.value|length)"' "$map" > "$indeg"
  local order=()
  while :; do
    local zeros; zeros="$(awk -F'\t' '$2==0{print $1}' "$indeg")"
    [[ -z "$zeros" ]] && break
    # escreve zeros na saída e marca como removidos
    while IFS= read -r z; do
      order+=( "$z" )
      awk -F'\t' -v z="$z" '$1!=z{print $0}' "$indeg" > "${indeg}.n" && mv -f "${indeg}.n" "$indeg"
      # remove z das listas de deps, decrementando indegree
      local tmp; tmp="$(tmpfile)"
      jq --arg z "$z" 'to_entries | map({key:.key, value:(.value - [$z])}) | from_entries' "$map" > "$tmp"
      mv -f "$tmp" "$map"
      # recalc indeg
      jq -r 'to_entries[] | "\(.key)\t\(.value|length)"' "$map" > "$indeg"
    done <<< "$zeros"
  done

  # se sobrou algo com indegree >0, temos ciclo -> empurra resto em ordem lex
  local rest; rest="$(awk -F'\t' '{print $1}' "$indeg")"
  printf '%s\n' "${order[@]}" | sed '/^$/d' > "$out"
  printf '%s\n' $rest | sed '/^$/d' | sort -u >> "$out"
}

lex_order(){
  local in="$1" out="$2"
  sort -u "$in" > "$out"
}

maybe_respect_world(){
  local in="$1" out="$2"
  [[ -r "$WORLD_FILE" ]] || { cp -f "$in" "$out"; return 0; }
  local world; world="$(tmpfile)"; grep -v '^\s*$' "$WORLD_FILE" > "$world" || true
  # primeiro os que estão no world (na ordem atual relativa), depois os demais
  local tmp1 tmp2; tmp1="$(tmpfile)"; tmp2="$(tmpfile)"
  grep -Fxf "$world" "$in" > "$tmp1" || true
  grep -Fvx -f "$world" "$in" > "$tmp2" || true
  cat "$tmp1" "$tmp2" > "$out"
}

###############################################################################
# MAIN
###############################################################################
bp_run(){
  parse_cli "$@"

  # logging opcional
  if [[ -n "$LOGPATH" ]]; then
    exec > >(tee -a "$LOGPATH") 2>&1
  fi

  __lock "bulk-update-planner"
  bp_hooks_run "pre-plan"

  # diretório desta execução
  local TS; TS="$(now_ts)"
  local RUN_DIR="${ADM_STATE_DIR}/bulk-update/${TS}"
  __ensure_dir "$RUN_DIR"

  # 1) coleta escopo
  local refs all filtered
  refs="$(tmpfile)"; all="$(tmpfile)"; filtered="$(tmpfile)"
  collect_scope "$all"
  __filter_by_categories "$all" "$refs"
  __apply_exclude "$refs" "$filtered"

  # 2) executa trackers em paralelo
  bp_info "Executando tracker para $(wc -l < "$filtered") pacotes… (P=${PARALLEL_TRACKER})"
  local rawdir="${RUN_DIR}/raw"; __ensure_dir "$rawdir"
  local plan_tmp; plan_tmp="$(tmpfile)"
  run_trackers_parallel "$filtered" "$rawdir" "$plan_tmp"

  # 3) agrega JSONs
  local plan_json; plan_json="$(tmpfile)"
  cat "$plan_tmp" | jq_or_cat_array > "$plan_json"

  # 4) filtra somente 'ok' (nova versão) quando ONLY_NEW=1
  local plan_ok; plan_ok="$(tmpfile)"
  if adm_is_cmd jq; then
    if (( ONLY_NEW )); then
      jq '[ .[] | select(.status=="ok") ]' "$plan_json" > "$plan_ok" 2>/dev/null || echo "[]" > "$plan_ok"
    else
      jq '.' "$plan_json" > "$plan_ok" 2>/dev/null || cat "$plan_json" > "$plan_ok"
    fi
  else
    cp -f "$plan_json" "$plan_ok"
  fi

  # 5) extrai refs candidatos
  local cand refs_ordered; cand="$(tmpfile)"; refs_ordered="$(tmpfile)"
  if adm_is_cmd jq; then
    jq -r '.[] | "\(.category)/\(.name)"' "$plan_ok" | sed '/^\/$/d' > "$cand" 2>/dev/null || : > "$cand"
  else
    # modo degradado: tenta extrair com regex pobre
    sed -nE 's/.*"category":"([^"]+)".*"name":"([^"]+)".*/\1\/\2/p' "$plan_ok" > "$cand" || true
  fi

  # 6) ordenar pela dependência (se disponível)
  if (( ORDER_BY_GRAPH )) && [[ -r "${GRAPH_DIR}/deps.json" ]] && adm_is_cmd jq; then
    toposort_with_graph "$cand" "$refs_ordered" || lex_order "$cand" "$refs_ordered"
  else
    lex_order "$cand" "$refs_ordered"
  fi
  if (( RESPECT_WORLD )); then
    local tmpw; tmpw="$(tmpfile)"
    maybe_respect_world "$refs_ordered" "$tmpw" && mv -f "$tmpw" "$refs_ordered"
  fi

  # 7) salva plano final
  local OUT_PLAN_DIR="${RUN_DIR}/plan"
  __ensure_dir "$OUT_PLAN_DIR"
  cp -f "$plan_ok" "${OUT_PLAN_DIR}/updates.json"
  cp -f "$refs_ordered" "${OUT_PLAN_DIR}/order.lst"

  # 8) se JSON_OUT, imprime resumo em JSON; senão, tabela breve
  if (( JSON_OUT )) && adm_is_cmd jq; then
    jq -n \
      --arg run_dir "$RUN_DIR" \
      --argfile updates "${OUT_PLAN_DIR}/updates.json" \
      --argfile order <(jq -R -s 'split("\n")|map(select(length>0))' "${OUT_PLAN_DIR}/order.lst") \
      '{run_dir:$run_dir, updates:$updates, order:$order}'
  else
    bp_ok "Plano salvo em: ${OUT_PLAN_DIR}"
    echo "--- Ordem sugerida ---"
    nl -ba "${OUT_PLAN_DIR}/order.lst" || true
    echo
    echo "--- Resumo de updates ---"
    if adm_is_cmd jq; then
      jq -r '.[] | "- \(.category)/\(.name): \(.current // "?") -> \(.new // "?") [\(.provider // "?")]"' "${OUT_PLAN_DIR}/updates.json" || cat "${OUT_PLAN_DIR}/updates.json"
    else
      cat "${OUT_PLAN_DIR}/updates.json"
    fi
  fi

  bp_hooks_run "post-plan" "RUN_DIR=${RUN_DIR}" "PLAN_DIR=${OUT_PLAN_DIR}"
  __unlock
  bp_ok "Concluído."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  bp_run "$@"
fi
