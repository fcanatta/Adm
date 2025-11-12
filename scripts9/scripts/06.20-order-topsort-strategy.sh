#!/usr/bin/env bash
# 06.20-order-toposort-strategy.sh
# Orquestrador de construção por topological sort + waves paralelas.
###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__ots_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] order-toposort-strategy falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __ots_err_trap ERR
###############################################################################
# Caminhos, logging, utilitários
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_RUNS_DIR="${ADM_RUNS_DIR:-${ADM_STATE_DIR}/runs}"
ADM_META_DIR="${ADM_META_DIR:-${ADM_ROOT}/metafiles}"

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
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_TMPDIR"; __ensure_dir "$ADM_LOG_DIR"; __ensure_dir "$ADM_RUNS_DIR"

# Cores simples
if [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
ots_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
ots_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
ots_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
ots_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
tmpfile(){ mktemp "${ADM_TMPDIR}/ots.XXXXXX"; }
trim(){ sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

###############################################################################
# CLI
###############################################################################
OTS_ROOT=""                 # cat/pkg ou pkg (igual 06.10)
OTS_TARGET="all"            # run|build|all
OTS_INCLUDE_OPT=0
OTS_MAX_PAR="${JOBS:-$(adm_is_cmd nproc && nproc || echo 2)}"
OTS_PLAN=""                 # caminho do plan.json (opcional)
OTS_OUTDIR=""               # onde salvar run.json/logs desta execução
OTS_RETRIES=1
OTS_BACKOFF="2,5,10"        # segundos (csv) se RETRIES>1
OTS_TIMEOUT=0               # 0 = sem timeout para cada pacote
OTS_ONLY=""                 # allowlist CSV (cat/pkg ou pkg)
OTS_SKIP=""                 # denylist CSV
OTS_SKIP_BUILT=1            # pular se detectado como já construído
OTS_CONTINUE_ON_FAIL=0      # 0 = aborta em falha (default); 1 = continua
OTS_DRYRUN=0
OTS_PRIORITY=""             # CSV de pacotes prioritários (executa antes na mesma wave)
OTS_ENV_EXPORTS=""          # CSV: KEY=VALUE,KEY2=VALUE2
OTS_DESTROOT="${ADM_STATE_DIR}/destdir"  # raiz para DESTDIRs individuais (staging)
OTS_BUILD_DRIVER=""         # comando para construir um pacote; v. defaults
OTS_LOG_PREFIX=""           # prefixo no nome dos logs (opcional)

ots_usage(){
  cat <<'EOF'
Uso:
  06.20-order-toposort-strategy.sh --root <cat/pkg|pkg> [opções]

Plano/Ordenação:
  --plan PATH                  plan.json (opcional; se ausente, gera com 06.10)
  --target {run|build|all}     (default: all)
  --include-optional           inclui opt_deps
  --max-par N                  paralelismo máximo (default: nproc)
  --priority CSV               lista de pacotes a priorizar dentro da mesma wave
  --only CSV                   allowlist (somente estes)
  --skip CSV                   denylist (pular estes)
  --skip-built                 pular os já construídos (default)
  --no-skip-built              força reconstrução
  --continue-on-fail           não aborta a execução se algum falhar
  --dry-run                    não executa builds; apenas imprime ordem/plan

Execução:
  --retries N                  número de tentativas p/ pacote (default: 1)
  --backoff CSV                atrasos entre tentativas (ex: 2,5,10)
  --timeout SEC                timeout por pacote (0 = desativado)
  --env "K=V,K2=V2"            exports extras para o ambiente do worker
  --destroot DIR               base para DESTDIRs (default: ${ADM_STATE_DIR}/destdir)
  --driver CMD                 comando de build (default: auto)
  --outdir DIR                 diretório para artefatos desta execução

Geral:
  --help
EOF
}

parse_cli(){
  while (($#)); do
    case "$1" in
      --root) OTS_ROOT="${2:-}"; shift 2 ;;
      --plan) OTS_PLAN="${2:-}"; shift 2 ;;
      --target) OTS_TARGET="${2:-all}"; shift 2 ;;
      --include-optional) OTS_INCLUDE_OPT=1; shift ;;
      --max-par) OTS_MAX_PAR="${2:-$OTS_MAX_PAR}"; shift 2 ;;
      --priority) OTS_PRIORITY="${2:-}"; shift 2 ;;
      --only) OTS_ONLY="${2:-}"; shift 2 ;;
      --skip) OTS_SKIP="${2:-}"; shift 2 ;;
      --skip-built) OTS_SKIP_BUILT=1; shift ;;
      --no-skip-built) OTS_SKIP_BUILT=0; shift ;;
      --continue-on-fail) OTS_CONTINUE_ON_FAIL=1; shift ;;
      --dry-run) OTS_DRYRUN=1; shift ;;
      --retries) OTS_RETRIES="${2:-1}"; shift 2 ;;
      --backoff) OTS_BACKOFF="${2:-2,5,10}"; shift 2 ;;
      --timeout) OTS_TIMEOUT="${2:-0}"; shift 2 ;;
      --env) OTS_ENV_EXPORTS="${2:-}"; shift 2 ;;
      --destroot) OTS_DESTROOT="${2:-$OTS_DESTROOT}"; shift 2 ;;
      --driver) OTS_BUILD_DRIVER="${2:-}"; shift 2 ;;
      --outdir) OTS_OUTDIR="${2:-}"; shift 2 ;;
      --help|-h) ots_usage; exit 0 ;;
      *) ots_err "opção inválida: $1"; ots_usage; exit 2 ;;
    esac
  done
  if [[ -z "$OTS_ROOT" ]]; then
    local cat="${ADM_META[category]:-}" name="${ADM_META[name]:-}"
    [[ -n "$cat" && -n "$name" ]] && OTS_ROOT="${cat}/${name}" || { ots_err "falta --root"; exit 3; }
  fi
  case "$OTS_TARGET" in run|build|all) : ;; *) ots_err "--target inválido"; exit 2;; esac
  [[ "$OTS_MAX_PAR" =~ ^[0-9]+$ && "$OTS_MAX_PAR" -ge 1 ]] || { ots_err "--max-par inválido"; exit 2; }
  [[ "$OTS_RETRIES" =~ ^[0-9]+$ && "$OTS_RETRIES" -ge 1 ]] || { ots_err "--retries inválido"; exit 2; }
  [[ "$OTS_TIMEOUT" =~ ^[0-9]+$ ]] || { ots_err "--timeout inválido"; exit 2; }
}

###############################################################################
# Plano (plan.json) e ordenação
###############################################################################
# Estruturas: TOPO_ORDER[], WAVES[(string com nós separados por espaço)]
declare -a TOPO_ORDER WAVES

__path_for_plan(){
  # tenta plan.json default de 06.10
  local key="$1"
  local cat="${key%%/*}" pkg="${key#*/}"
  echo "${ADM_STATE_DIR}/deps/${cat}/${pkg}/plan.json"
}

__load_plan(){
  local key="$1"
  local plan="${OTS_PLAN:-$(__path_for_plan "$key")}"
  if [[ ! -r "$plan" ]]; then
    ots_warn "plan.json ausente; gerando com 06.10-resolve-deps-graph.sh…"
    if [[ -r "${ADM_ROOT}/scripts/06.10-resolve-deps-graph.sh" ]]; then
      "${ADM_ROOT}/scripts/06.10-resolve-deps-graph.sh" --root "$key" \
        --target "$OTS_TARGET" $([[ $OTS_INCLUDE_OPT -eq 1 ]] && echo --include-optional || true) \
        --format all >/dev/null
    else
      ots_err "script 06.10-resolve-deps-graph.sh não encontrado"
      exit 10
    fi
  fi
  [[ -r "$plan" ]] || { ots_err "plan.json ainda indisponível"; exit 11; }

  if adm_is_cmd jq; then
    mapfile -t TOPO_ORDER < <(jq -r '.order[]' "$plan")
    # waves vem como arrays; reconstituir string por wave
    local wc; wc="$(jq '(.waves // []) | length' "$plan")"
    WAVES=()
    local i; for ((i=0;i<wc;i++)); do
      WAVES+=( "$(jq -r ".waves[$i][] | @sh" "$plan" | tr -d "'" | tr '\n' ' ' | sed 's/ $//')" )
    done
  else
    # fallback (rudimentar): tenta ler linhas; não é perfeito mas evita travar
    mapfile -t TOPO_ORDER < <(sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*,\?$/\1/p' "$plan" | sed -n '1,1000p')
    WAVES=( "${TOPO_ORDER[*]}" )
  fi
  OTS_PLAN="$plan"
}

###############################################################################
# Allowlist / Denylist / Prioridades
###############################################################################
__csv_to_set(){  # in: "a,b,c" -> print each
  [[ -n "$1" ]] || return 0
  echo "$1" | tr ',' '\n' | trim | sed '/^$/d'
}
__is_in_set(){
  local item="$1"; shift
  local x; for x in "$@"; do [[ "$item" == "$x" ]] && return 0; done
  return 1
}
__filter_wave(){
  # aplica allowlist/denylist e ordena por prioridade dentro da wave
  local wave="$1"
  local -a items=() prio=() only=() deny=()
  mapfile -t prio < <(__csv_to_set "$OTS_PRIORITY")
  mapfile -t only < <(__csv_to_set "$OTS_ONLY")
  mapfile -t deny < <(__csv_to_set "$OTS_SKIP")
  for x in $wave; do
    # denylist
    if __is_in_set "$x" "${deny[@]}"; then continue; fi
    # allowlist
    if ((${#only[@]}>0)); then
      __is_in_set "$x" "${only[@]}" || continue
    fi
    items+=( "$x" )
  done
  # prioriza: os que estão em prio[] vão primeiro, mantendo ordem estável
  local -a out=() rest=()
  for x in "${items[@]}"; do
    __is_in_set "$x" "${prio[@]}" && out+=( "$x" ) || rest+=( "$x" )
  done
  printf '%s\n' "${out[@]}" "${rest[@]}"
}

###############################################################################
# Estado de execução / logs
###############################################################################
__mk_run_dirs(){
  local key="$1"
  local stamp; stamp="${OTS_LOG_PREFIX}$(date -u +%Y%m%d-%H%M%S)"
  local cat="${key%%/*}" pkg="${key#*/}"
  OTS_OUTDIR="${OTS_OUTDIR:-${ADM_RUNS_DIR}/${cat}/${pkg}/${stamp}}"
  __ensure_dir "$OTS_OUTDIR"
  RUN_JSON="${OTS_OUTDIR}/run.json"
  RUN_SUMMARY="${OTS_OUTDIR}/summary.txt"
  RUN_LOGDIR="${OTS_OUTDIR}/logs"; __ensure_dir "$RUN_LOGDIR"
  echo '{}' > "$RUN_JSON"
}

__status_set(){
  # __status_set <node> <STATUS> [message]
  local node="$1" st="$2" msg="${3:-}"
  local now; now="$(date -u +%FT%TZ)"
  if adm_is_cmd jq; then
    local tmp; tmp="$(tmpfile)"
    jq --arg n "$node" --arg s "$st" --arg m "$msg" --arg t "$now" \
       '.[$n] = {status:$s, message:$m, ts:$t}' "$RUN_JSON" > "$tmp" 2>/dev/null || cp -f "$RUN_JSON" "$tmp"
    mv -f "$tmp" "$RUN_JSON"
  else
    printf '%s %s %s\n' "$node" "$st" "$msg" >> "$RUN_SUMMARY"
  fi
}

###############################################################################
# Descoberta de driver de build e preparação do pacote
###############################################################################
__discover_driver(){
  # Ordem: OTS_BUILD_DRIVER > hook custom > 05.10-applypatches-build.sh
  if [[ -n "$OTS_BUILD_DRIVER" ]]; then
    echo "$OTS_BUILD_DRIVER"; return 0
  fi
  if [[ -x "${ADM_ROOT}/hooks/build-driver" ]]; then
    echo "${ADM_ROOT}/hooks/build-driver"; return 0
  fi
  if [[ -x "${ADM_ROOT}/scripts/05.10-applypatches-build.sh" ]]; then
    echo "${ADM_ROOT}/scripts/05.10-applypatches-build.sh"; return 0
  fi
  echo "" ; return 0
}

__prepare_pipeline_if_needed(){
  # Tenta garantir um WORKDIR pronto para o pacote em ${ADM_STATE_DIR}/work/<cat>/<pkg>
  local key="$1" cat="${key%%/*}" pkg="${key#*/}"
  local wdir="${ADM_STATE_DIR}/work/${cat}/${pkg}"
  [[ -d "$wdir" && -n "$(ls -A "$wdir" 2>/dev/null || true)" ]] && { echo "$wdir"; return 0; }

  # Tentativas de pipeline (se scripts existirem): 03.x fetch/verify → 04.10 extract → 04.20 matrix
  local ok=0
  if [[ -r "${ADM_ROOT}/scripts/03.10-hooks-fetch-verify.sh" ]]; then
    # shellcheck disable=SC1090
    source "${ADM_ROOT}/scripts/03.10-hooks-fetch-verify.sh" || true
  fi
  if [[ -r "${ADM_ROOT}/scripts/04.10-extract-detect.sh" ]]; then
    # shellcheck disable=SC1090
    source "${ADM_ROOT}/scripts/04.10-extract-detect.sh" || true
  fi
  if [[ -r "${ADM_ROOT}/scripts/04.20-source-heuristics-matrix.sh" ]]; then
    # shellcheck disable=SC1090
    source "${ADM_ROOT}/scripts/04.20-source-heuristics-matrix.sh" || true
  fi

  # Fetch + verify (se funções disponíveis)
  if declare -F adm_fetch_hooks >/dev/null 2>&1; then
    __ensure_dir "$wdir"
    if adm_fetch_hooks "$key" "$wdir"; then ok=1; fi
  fi

  # Extract + detect
  if declare -F adm_extract >/dev/null 2>&1; then
    local cache="${ADM_STATE_DIR}/cache/${cat}/${pkg}"
    __ensure_dir "$cache"; __ensure_dir "$wdir"
    # Se já baixado, apenas extrai
    if compgen -G "$cache/*" >/dev/null; then
      local tmp; tmp="$(mktemp -d "${ADM_TMPDIR}/ots-w.XXXX")"
      for f in "$cache"/*; do adm_extract "$f" "$tmp" >/dev/null || true; done
      # mover para wdir
      shopt -s dotglob; cp -a "$tmp"/* "$wdir"/ || true; shopt -u dotglob
      rm -rf "$tmp"
      ok=1
    fi
  fi

  # Detect + heuristics
  if [[ $ok -eq 1 ]]; then
    if declare -F adm_detect_all >/dev/null 2>&1; then adm_detect_all "$wdir" || true; fi
    if declare -F shm_build_matrix >/dev/null 2>&1; then shm_build_matrix "$wdir" || true; fi
    echo "$wdir"; return 0
  fi

  # fallback: se diretório já existir vazio, apenas devolve
  __ensure_dir "$wdir"; echo "$wdir"
}

###############################################################################
# Skip built (registro simples)
###############################################################################
__is_already_built(){
  # Considera "instalado" se existe registro em ${ADM_ROOT}/db/installed/<cat>/<pkg>
  local key="$1" cat="${key%%/*}" pkg="${key#*/}"
  local mark="${ADM_ROOT}/db/installed/${cat}/${pkg}/.installed"
  [[ -f "$mark" ]]
}
###############################################################################
# Worker de build (com retries, timeout, env extra)
###############################################################################
__run_with_timeout(){
  local sec="$1"; shift
  if (( sec > 0 )) && adm_is_cmd timeout; then
    timeout --kill-after=30s "${sec}s" -- "$@"
  else
    "$@"
  fi
}

__sleep_backoff_idx(){
  local idx="$1"
  local arr; IFS=',' read -r -a arr <<< "$OTS_BACKOFF"
  local v="${arr[$((idx-1))]:-0}"
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  (( v > 0 )) && sleep "$v" || true
}

build_one(){
  # build_one <node cat/pkg>  → escreve logs em RUN_LOGDIR e retorna 0/!=0
  local node="$1"
  local log="${RUN_LOGDIR}/$(echo "$node" | tr '/' '_').log"
  local cat="${node%%/*}" pkg="${node#*/}"
  local dest="${OTS_DESTROOT}/${cat}/${pkg}"
  __ensure_dir "$dest"

  # Skip se já instalado/registrado
  if (( OTS_SKIP_BUILT )) && __is_already_built "$node"; then
    ots_info "SKIP (already built): $node"
    __status_set "$node" "SKIPPED" "already built"
    return 0
  fi

  # Descobrir driver
  local driver; driver="$(__discover_driver)"
  [[ -n "$driver" ]] || { ots_err "nenhum driver de build encontrado"; return 99; }

  # Preparar WORKDIR (se necessário)
  local workdir; workdir="$(__prepare_pipeline_if_needed "$node")"

  # Exports extras
  if [[ -n "$OTS_ENV_EXPORTS" ]]; then
    IFS=',' read -r -a kvs <<< "$OTS_ENV_EXPORTS"
    local kv; for kv in "${kvs[@]}"; do
      [[ "$kv" == *"="* ]] && export "${kv%%=*}"="${kv#*=}"
    done
  fi

  local attempt=1 rc=1
  while (( attempt <= OTS_RETRIES )); do
    ots_info "BUILD [$attempt/$OTS_RETRIES]: $node → driver=$(basename "$driver")"
    {
      echo "== $(date -u +%FT%TZ) :: node=$node attempt=$attempt =="
      echo "WORKDIR=$workdir DESTDIR=$dest"
      echo "DRIVER=$driver"
    } >> "$log"

    if __run_with_timeout "$OTS_TIMEOUT" "$driver" --workdir "$workdir" --destdir "$dest" \
         $([[ -n "${ADM_PROFILE:-}" ]] && echo --profile "$ADM_PROFILE") \
         $([[ -n "${ADM_LIBC:-}"    ]] && echo --libc "$ADM_LIBC") \
         $([[ "${OTS_DRYRUN}" == "1" ]] && echo --help || true) \
         >> "$log" 2>&1; then
      rc=0; break
    else
      rc=$?
      echo "!! FAIL attempt=$attempt rc=$rc" >> "$log"
      (( attempt < OTS_RETRIES )) && __sleep_backoff_idx "$((attempt))"
      (( attempt++ ))
    fi
  done

  if (( rc==0 )); then
    __status_set "$node" "SUCCEEDED" ""
    ots_ok "OK: $node"
  else
    __status_set "$node" "FAILED" "rc=$rc"
    ots_err "FAIL rc=$rc: $node (log: $log)"
  fi
  return "$rc"
}

###############################################################################
# Execução por waves (paralelo com limite)
###############################################################################
run_waves(){
  local -a failed=() succeeded=() skipped=()
  local wave nodes node
  for wave in "${WAVES[@]}"; do
    # filtra allow/deny/prioridades
    mapfile -t nodes < <(__filter_wave "$wave")
    ((${#nodes[@]})) || continue

    ots_info "==== WAVE ====: ${nodes[*]}"
    declare -A pmap=() ; local running=0
    for node in "${nodes[@]}"; do
      # controle de slots
      while (( running >= OTS_MAX_PAR )); do
        for pid in "${!pmap[@]}"; do
          if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" || true
            unset 'pmap[$pid]'
            ((running--))
          fi
        done
        sleep 0.2
      done

      # DRYRUN só mostra
      if (( OTS_DRYRUN )); then
        ots_info "(dry-run) build $node"
        skipped+=( "$node" )
        continue
      fi

      # dispara worker
      (
        set -Eeuo pipefail
        if build_one "$node"; then
          echo "OK $node"
        else
          echo "FAIL $node"
        fi
      ) &
      pmap[$!]="$node"; ((running++))
    done

    # aguarda wave
    for pid in "${!pmap[@]}"; do
      if wait "$pid"; then
        succeeded+=( "${pmap[$pid]}" )
      else
        failed+=( "${pmap[$pid]}" )
      fi
    done

    # se houver falhas e não pode continuar, aborta
    if ((${#failed[@]}>0)) && (( OTS_CONTINUE_ON_FAIL == 0 )); then
      ots_err "Falhas na wave; abortando devido a --continue-on-fail ausente."
      break
    fi
  done

  # Coleta SKIPPED do run.json (quando houve skip-built)
  if adm_is_cmd jq && [[ -r "$RUN_JSON" ]]; then
    mapfile -t skipped < <(jq -r 'to_entries[] | select(.value.status=="SKIPPED") | .key' "$RUN_JSON")
  fi

  # Resumo
  {
    echo "==== RESUMO ===="
    echo "SUCCEEDED (${#succeeded[@]}): ${succeeded[*]:-}"
    echo "FAILED    (${#failed[@]}): ${failed[*]:-}"
    echo "SKIPPED   (${#skipped[@]}): ${skipped[*]:-}"
  } | tee -a "$RUN_SUMMARY"

  # código de saída
  ((${#failed[@]}>0)) && return 32 || return 0
}

###############################################################################
# MAIN
###############################################################################
ots_run(){
  parse_cli "$@"
  __load_plan "$OTS_ROOT"
  __mk_run_dirs "$OTS_ROOT"

  ots_info "Plano: $OTS_PLAN"
  ots_info "Waves: ${#WAVES[@]}  | Paralelismo: ${OTS_MAX_PAR}  | Retries: ${OTS_RETRIES}  | Timeout: ${OTS_TIMEOUT}s"
  (( OTS_DRYRUN )) && ots_warn "DRY-RUN ativo: builds não serão executados."

  if run_waves; then
    ots_ok "Execução concluída. Artefatos: $(realpath -m "$OTS_OUTDIR")"
  else
    ots_err "Execução finalizou com falhas. Artefatos: $(realpath -m "$OTS_OUTDIR")"
    exit 32
  fi
}

###############################################################################
# Execução direta
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ots_run "$@"
fi
