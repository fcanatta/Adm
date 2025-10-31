#!/usr/bin/env bash
#=============================================================
# scheduler.sh — Orquestrador de builds do ADM Build System
#=============================================================
# Funções:
#  - monta grafo de dependências a partir de repo/*/*/build.pkg
#  - resolve ordem topológica (Kahn)
#  - executa pipeline: fetch -> build -> package -> install
#  - suporta execução paralela (-j N)
#  - suporta --retry-failed, --build-only, --install-only, --dry-run
#  - registra estado em state/ e logs/
#=============================================================

set -o pipefail
[[ -n "${ADM_SCHEDULER_SH_LOADED}" ]] && return
ADM_SCHEDULER_SH_LOADED=1

#-------------------------------------------------------------
# Safety & env
#-------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" && ! -f "/usr/src/adm/scripts/env.sh" ]]; then
    echo "❌ Este script deve ser executado dentro do ambiente ADM."
    exit 1
fi

# Load core modules (abort if missing)
source /usr/src/adm/scripts/env.sh
source /usr/src/adm/scripts/log.sh
source /usr/src/adm/scripts/utils.sh
source /usr/src/adm/scripts/ui.sh
source /usr/src/adm/scripts/hooks.sh

# External pipelines (may be called by scheduler)
# build.sh, package.sh, install.sh are expected to exist.
for mod in build.sh package.sh install.sh fetch.sh; do
    [[ -f "${ADM_ROOT}/scripts/${mod}" ]] || { echo "Módulo faltando: ${mod}"; exit 1; }
done
source "${ADM_ROOT}/scripts/fetch.sh"   || true
source "${ADM_ROOT}/scripts/build.sh"   || true
source "${ADM_ROOT}/scripts/package.sh" || true
source "${ADM_ROOT}/scripts/install.sh" || true

#-------------------------------------------------------------
# Configuration / paths
#-------------------------------------------------------------
STATE_DIR="${ADM_ROOT}/state"
QUEUE_FILE="${STATE_DIR}/build.queue"
STATUS_FILE="${STATE_DIR}/build.status"
LOG_DIR="${ADM_LOG_DIR}/scheduler"
ensure_dir "$STATE_DIR"
ensure_dir "$LOG_DIR"

# Defaults
JOBS=1
DRY_RUN=0
RETRY_FAILED=0
BUILD_ONLY=0
INSTALL_ONLY=0

# Temporary structures
declare -A PKG_TO_PKGDIR      # PKG_NAME -> repo dir (where build.pkg lives)
declare -A DEPS_MAP          # PKG_NAME -> "dep1 dep2 ..."
declare -A REVERSE_ADJ       # dep -> space separated list of dependents
declare -A INDEGREE          # PKG_NAME -> indegree count
declare -A SEEN              # helpers
BUILD_ORDER=()

#-------------------------------------------------------------
# Utilities
#-------------------------------------------------------------
log_and_ui_header() {
    local title="$1"
    ui_draw_header "scheduler" "$title"
    print_section "$title"
}

# find all build.pkg and populate PKG_TO_PKGDIR and DEPS_MAP
scan_repo_metadata() {
    PKG_TO_PKGDIR=()
    DEPS_MAP=()
    # find build.pkg files
    while IFS= read -r -d '' file; do
        pkgdir=$(dirname "$file")
        # shellcheck disable=SC1090
        source "$file"
        # require PKG_NAME
        if [[ -z "${PKG_NAME:-}" ]]; then
            log_warn "build.pkg sem PKG_NAME em: $file"
            continue
        fi
        PKG_TO_PKGDIR["$PKG_NAME"]="$pkgdir"
        # normalize dependencies array if present
        if [[ -n "${PKG_DEPENDS[*]:-}" ]]; then
            DEPS_MAP["$PKG_NAME"]="${PKG_DEPENDS[*]}"
        else
            DEPS_MAP["$PKG_NAME"]=""
        fi
    done < <(find "${ADM_REPO_DIR}" -type f -name "build.pkg" -print0 2>/dev/null)
}

# Build dependency graph (adjacency and indegree)
build_graph() {
    REVERSE_ADJ=()
    INDEGREE=()
    for pkg in "${!PKG_TO_PKGDIR[@]}"; do
        INDEGREE["$pkg"]=0
    done

    for pkg in "${!PKG_TO_PKGDIR[@]}"; do
        deps="${DEPS_MAP[$pkg]}"
        if [[ -n "$deps" ]]; then
            for d in $deps; do
                # ensure nodes for deps even if we don't have build.pkg (external)
                if [[ -z "${INDEGREE[$d]:-}" ]]; then
                    INDEGREE["$d"]=0
                fi
                # add edge d -> pkg (d is prerequisite of pkg)
                REVERSE_ADJ["$d"]="${REVERSE_ADJ[$d]} $pkg"
                INDEGREE["$pkg"]=$((INDEGREE["$pkg"] + 1))
            done
        fi
    done
}

# Topological sort using Kahn's algorithm for a subset of targets
# Input: targets as array
resolve_build_order_for_targets() {
    local targets=("$@")
    BUILD_ORDER=()
    declare -A indeg_local
    declare -A rev_local
    # Copy global structures to locals to allow pruning
    for k in "${!INDEGREE[@]}"; do indeg_local["$k"]=${INDEGREE[$k]}; done
    for k in "${!REVERSE_ADJ[@]}"; do rev_local["$k"]=${REVERSE_ADJ[$k]}; done

    # We only need nodes reachable from targets: perform reverse BFS to find required set
    declare -A required
    queue=()
    for t in "${targets[@]}"; do
        required["$t"]=1
        queue+=("$t")
    done
    while ((${#queue[@]})); do
        node="${queue[0]}"; queue=("${queue[@]:1}")
        # for each dep of node, add to required
        # we need original DEPS_MAP which maps node -> deps
        deps="${DEPS_MAP[$node]}"
        for d in $deps; do
            if [[ -z "${required[$d]:-}" ]]; then
                required["$d"]=1
                queue+=("$d")
            fi
        done
    done

    # prepare Kahn: initial nodes with indegree 0 among required
    q=()
    for node in "${!required[@]}"; do
        # ensure exists in indeg_local
        : "${indeg_local[$node]:=0}"
        if [[ "${indeg_local[$node]}" -eq 0 ]]; then
            q+=("$node")
        fi
    done

    while ((${#q[@]})); do
        n="${q[0]}"; q=("${q[@]:1}")
        # only append nodes that are required and exist in our PKG_TO_PKGDIR or are "virtual"
        BUILD_ORDER+=("$n")
        # for each dependent of n
        for depn in ${rev_local[$n]}; do
            # decrement
            indeg_local["$depn"]=$((indeg_local["$depn"] - 1))
            if [[ "${indeg_local[$depn]}" -eq 0 ]]; then
                q+=("$depn")
            fi
        done
    done

    # Verify that all required nodes are present in BUILD_ORDER (if cycle exists, missing)
    missing=()
    for node in "${!required[@]}"; do
        found=0
        for b in "${BUILD_ORDER[@]}"; do [[ "$b" == "$node" ]] && found=1 && break; done
        if [[ "$found" -ne 1 ]]; then missing+=("$node"); fi
    done
    if ((${#missing[@]})); then
        log_error "Dependência circular ou não-resolvida detectada: ${missing[*]}"
        return 1
    fi

    # remove duplicates while preserving order (some nodes may be appended multiple times)
    declare -A seen
    pruned=()
    for n in "${BUILD_ORDER[@]}"; do
        if [[ -z "${seen[$n]:-}" ]]; then
            seen["$n"]=1
            pruned+=("$n")
        fi
    done
    BUILD_ORDER=("${pruned[@]}")
    return 0
}

# Wait for available job slot (uses jobs -rp)
wait_for_slot() {
    while :; do
        local running
        # jobs -rp lists PIDs of running background jobs (bash builtin)
        running=$(jobs -rp 2>/dev/null | wc -l)
        if [[ "$running" -lt "$JOBS" ]]; then
            break
        fi
        sleep 0.25
    done
}

# Run pipeline for a single package (called in foreground or background)
run_pipeline_for_pkg() {
    local pkg="$1"
    local pkgdir="${PKG_TO_PKGDIR[$pkg]:-}"
    log_info "Pipeline start: $pkg"

    # If we don't have a local build.pkg for this package, we may be attempting to install an external dep;
    # try to find in repo (PKG_TO_PKGDIR mapping should contain it)
    if [[ -z "$pkgdir" ]]; then
        log_warn "Fonte não encontrada localmente para $pkg — procurando no repo..."
        pkgdir=$(find "${ADM_REPO_DIR}" -type f -name "build.pkg" -exec grep -l "PKG_NAME=\"${pkg}\"" {} \; | xargs -r dirname | head -n1 || true)
        if [[ -n "$pkgdir" ]]; then
            PKG_TO_PKGDIR["$pkg"]="$pkgdir"
        else
            log_error "Não foi possível localizar build.pkg para $pkg"
            echo "FAILED|$pkg|no-source" >>"$STATUS_FILE"
            return 1
        fi
    fi

    # prepare logs
    log_init
    log_info "Processing package: $pkg (dir: $pkgdir)"

    # call pre-scheduler hook per package
    call_hook "pre-scheduler" "$pkgdir" || true

    # 1) fetch (synchronizes only repo entries) - fetch.sh has sync mode, but here we just call fetch_all_local_packages via fetch.sh
    # Use fetch_package_from_metadata if available; fall back to fetch_all
    if declare -f fetch_package_from_metadata >/dev/null 2>&1; then
        fetch_package_from_metadata "$pkgdir" || { log_error "fetch failed: $pkg"; echo "FAILED|$pkg|fetch" >>"$STATUS_FILE"; return 1; }
    else
        fetch_all || true
    fi

    # 2) integrity
    if declare -f check_package_integrity >/dev/null 2>&1; then
        check_package_integrity "$pkgdir" || { log_error "integrity failed: $pkg"; echo "FAILED|$pkg|integrity" >>"$STATUS_FILE"; return 1; }
    fi

    # 3) build (if package artifact is not present in packages dir, build it)
    # detect package artifact name (package.sh creates packages/<group>/<name-version>.pkg.tar.*)
    local found_pkgfile
    found_pkgfile=$(find "${ADM_ROOT}/packages" -type f -name "${pkg}-*.pkg.tar.*" 2>/dev/null | sort -V | tail -n1 || true)
    if [[ -z "$found_pkgfile" ]]; then
        log_info "Artifact not found in cache for $pkg — building..."
        # call build_package from build.sh (ensure build.sh is sourced)
        if declare -f build_package >/dev/null 2>&1; then
            build_package "$pkgdir" || { log_error "build failed: $pkg"; echo "FAILED|$pkg|build" >>"$STATUS_FILE"; return 1; }
            # After build, call package.sh to create artifact
            if declare -f package_main >/dev/null 2>&1; then
                source "${ADM_ROOT}/scripts/package.sh" >/dev/null 2>&1 || true
                package_main "$pkgdir" || { log_error "package failed: $pkg"; echo "FAILED|$pkg|package" >>"$STATUS_FILE"; return 1; }
            fi
        else
            log_error "build_package not available to build $pkg"
            echo "FAILED|$pkg|no-builder" >>"$STATUS_FILE"
            return 1
        fi
        # try find again
        found_pkgfile=$(find "${ADM_ROOT}/packages" -type f -name "${pkg}-*.pkg.tar.*" 2>/dev/null | sort -V | tail -n1 || true)
        if [[ -z "$found_pkgfile" ]]; then
            log_error "Após build ainda não foi encontrado artifact para $pkg"
            echo "FAILED|$pkg|no-artifact" >>"$STATUS_FILE"
            return 1
        fi
    fi

    # 4) install (unless scheduler called with build-only)
    if [[ "$BUILD_ONLY" -eq 1 ]]; then
        log_info "BUILD_ONLY set, skipping install for $pkg"
        echo "OK|$pkg|built" >>"$STATUS_FILE"
        return 0
    fi

    # call install.sh to install by package file (install.sh supports name or path)
    if declare -f install_with_deps >/dev/null 2>&1; then
        # we prefer to call install_with_deps with the package path to avoid rebuild attempts
        install_with_deps "$found_pkgfile" || { log_error "install failed: $pkg"; echo "FAILED|$pkg|install" >>"$STATUS_FILE"; return 1; }
    else
        # fallback: call external script
        "${ADM_ROOT}/scripts/install.sh" "$found_pkgfile" || { log_error "install failed external: $pkg"; echo "FAILED|$pkg|install" >>"$STATUS_FILE"; return 1; }
    fi

    # call post-scheduler hook per package
    call_hook "post-scheduler" "$pkgdir" || true

    echo "OK|$pkg|done" >>"$STATUS_FILE"
    log_info "Pipeline finished: $pkg"
    return 0
}

#-------------------------------------------------------------
# Runner: schedule jobs either sequential or parallel using background jobs
#-------------------------------------------------------------
execute_build_order() {
    local -n order_ref=$1
    local total=${#order_ref[@]}
    local idx=0
    rm -f "$STATUS_FILE"
    touch "$STATUS_FILE"

    for pkg in "${order_ref[@]}"; do
        idx=$((idx+1))
        log_info "Scheduling [$idx/$total] $pkg"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "DRY|$pkg|scheduled"
            continue
        fi

        wait_for_slot
        # start each job in background to allow parallelism
        ( run_pipeline_for_pkg "$pkg" ) &

    done

    # wait all background jobs to finish
    wait

    # summarize
    success=0; failed=0
    while IFS= read -r line; do
        case "$line" in
            OK\|*) success=$((success+1)) ;;
            FAILED\|*) failed=$((failed+1)) ;;
            *) ;;
        esac
    done < "$STATUS_FILE"

    log_info "Scheduler summary: success=$success failed=$failed total=$total"
    echo "SUMMARY: success=$success failed=$failed total=$total"
    return $((failed>0))
}

#-------------------------------------------------------------
# CLI handling and entrypoint
#-------------------------------------------------------------
_show_help() {
    cat <<EOF
scheduler.sh - ADM Build Scheduler

Uso:
  scheduler.sh [opções] <alvo...>

Alvos:
  <pkg>        - nome do pacote (ex: curl) ou grupo (ex: core)
  se nenhum alvo informado: processa todos os pacotes do repo

Opções:
  -j N         - executar até N tarefas em paralelo (default 1)
  --dry-run    - mostra ordem de build sem executar
  --retry-failed - tenta reaplicar jobs que falharam anteriormente
  --build-only - apenas build+package, não instala
  --install-only - apenas instala (assume artifacts já existam)
  --help
EOF
}

# parse args
ARGS=()
while (( "$#" )); do
    case "$1" in
        -j) JOBS="$2"; shift 2;;
        -j*) JOBS="${1#-j}"; shift;;
        --dry-run) DRY_RUN=1; shift;;
        --retry-failed) RETRY_FAILED=1; shift;;
        --build-only) BUILD_ONLY=1; shift;;
        --install-only) INSTALL_ONLY=1; shift;;
        --help|-h) _show_help; exit 0;;
        *) ARGS+=("$1"); shift;;
    esac
done

# main flow
log_init
log_and_ui_header "scheduler start"

# run pre-scheduler hooks
call_hook "pre-scheduler" "${ADM_ROOT}" || true

# scan repo
scan_repo_metadata
build_graph

# determine targets
targets=()
if ((${#ARGS[@]})); then
    for a in "${ARGS[@]}"; do
        # if group exists (dir under repo), expand to packages in group
        if [[ -d "${ADM_REPO_DIR}/${a}" ]]; then
            while IFS= read -r -d '' bf; do
                dd=$(dirname "$bf")
                # source to get PKG_NAME
                # shellcheck disable=SC1090
                source "$bf"
                targets+=("$PKG_NAME")
            done < <(find "${ADM_REPO_DIR}/${a}" -maxdepth 2 -type f -name "build.pkg" -print0)
        else
            # assume package name
            targets+=("$a")
        fi
    done
else
    # no args -> all packages
    for p in "${!PKG_TO_PKGDIR[@]}"; do targets+=("$p"); done
fi

# dedupe targets preserving order
declare -A _seen_t
t_filtered=()
for t in "${targets[@]}"; do
    if [[ -z "${_seen_t[$t]:-}" ]]; then _seen_t[$t]=1; t_filtered+=("$t"); fi
done
targets=("${t_filtered[@]}")

if ((${#targets[@]} == 0)); then
    log_warn "Nenhum alvo definido ou encontrado."
    log_close
    exit 1
fi

# resolve build order for targets (includes recursive deps)
if ! resolve_build_order_for_targets "${targets[@]}"; then
    call_hook "on-error" "${ADM_ROOT}" || true
    log_close
    exit 1
fi

# If dry-run: print order and exit
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY RUN: build order:"
    for b in "${BUILD_ORDER[@]}"; do echo "  - $b"; done
    log_close
    exit 0
fi

# Execute build order
execute_build_order BUILD_ORDER
rc=$?

# retry failed if requested
if [[ "$rc" -ne 0 && "$RETRY_FAILED" -eq 1 ]]; then
    log_info "Retrying failed jobs..."
    # collect failed packages from STATUS_FILE
    failed_pkgs=()
    while IFS= read -r line; do
        case "$line" in
            FAILED\|* )
                IFS='|' read -r _ pkg _reason <<<"$line"
                failed_pkgs+=("$pkg")
            ;;
        esac
    done < "$STATUS_FILE"
    if ((${#failed_pkgs[@]})); then
        resolve_build_order_for_targets "${failed_pkgs[@]}" || true
        execute_build_order BUILD_ORDER
        rc=$?
    fi
fi

# post-scheduler hooks
call_hook "post-scheduler" "${ADM_ROOT}" || true

log_and_ui_header "scheduler end"
log_close

exit $rc
