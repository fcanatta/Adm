#!/usr/bin/env bash
#=============================================================
# uninstall.sh — Desinstalador transacional do ADM Build System
#-------------------------------------------------------------
# Recursos:
#  - dry-run, force, purge, deps, keep-config, backup, json report
#  - análise de dependências reversas (previne quebras)
#  - backup automático / rollback em caso de erro
#  - pre/post uninstall hooks (globais e por-pacote)
#  - logs em texto + JSON
#  - transação: move arquivos para tmp e só remove definitivamente após sucesso
#=============================================================
set -o errexit
set -o nounset
set -o pipefail

# prevent double load when sourced
[[ -n "${ADM_UNINSTALL_SH_LOADED:-}" ]] && return 0
ADM_UNINSTALL_SH_LOADED=1

# environment check
if [[ "${BASH_SOURCE[0]}" == "${0}" && ! -f "/usr/src/adm/scripts/env.sh" ]]; then
    echo "❌ Este script deve ser executado dentro do ambiente ADM."
    exit 1
fi

# load helpers (best-effort)
source /usr/src/adm/scripts/env.sh
source /usr/src/adm/scripts/log.sh    2>/dev/null || true
source /usr/src/adm/scripts/ui.sh     2>/dev/null || true
source /usr/src/adm/scripts/hooks.sh  2>/dev/null || true
source /usr/src/adm/scripts/utils.sh  2>/dev/null || true

# Paths (configurable via env.sh)
STATUS_DB="${ADM_STATUS_DB:-/var/lib/adm/status.db}"
INSTALLED_DIR="${ADM_INSTALLED_DIR:-/var/lib/adm/installed}"
LOG_DIR="${ADM_LOG_DIR:-/usr/src/adm/logs}/uninstall"
STATE_DIR="${ADM_ROOT}/state"
TMP_UNINSTALL="${STATE_DIR}/uninstall-tmp"
ROLLBACK_DIR="${STATE_DIR}/rollback"
PACKAGES_DIR="${ADM_ROOT}/packages"

mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${TMP_UNINSTALL}" "${ROLLBACK_DIR}" "${INSTALLED_DIR}"

# Defaults
DRY_RUN=0
FORCE=0
PURGE=0
REMOVE_DEPS=0
KEEP_CONFIG=0
BACKUP=0
JSON_OUT=0
INTERACTIVE=1
SILENT=0

# Helpers
_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
now_ts() { date '+%Y-%m-%d_%H-%M-%S'; }
logfile_text() { printf "%s/uninstall-%s.log" "${LOG_DIR}" "$1"; }
logfile_json() { printf "%s/uninstall-%s.json" "${LOG_DIR}" "$1"; }

echo_log() {
    local lvl="$1"; shift
    local msg="$*"
    if declare -f log_info >/dev/null 2>&1; then
        case "$lvl" in
            INFO) log_info "$msg" ;;
            WARN) log_warn "$msg" ;;
            ERROR) log_error "$msg" ;;
            *) log_info "$msg" ;;
        esac
    else
        printf "[%s] %s\n" "$lvl" "$msg"
    fi
}

# Read status.db into associative map: INSTALLED[pkg]=line
declare -A INSTALLED
load_status_db() {
    INSTALLED=()
    if [[ -f "$STATUS_DB" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            pkg=$(printf "%s" "$line" | awk -F'|' '{print $1}')
            INSTALLED["$pkg"]="$line"
        done < "$STATUS_DB"
    fi
}

# Find reverse dependents by scanning packages' pkginfo (in cache) and repo build.pkg as fallback.
find_reverse_deps() {
    local target="$1"
    local -n _out=$2
    _out=()
    # scan cached pkginfo files (packages/*/*.pkginfo)
    while IFS= read -r pkginfo; do
        [[ -z "$pkginfo" ]] && continue
        name=$(awk -F'= ' '/^pkgname/{print $2}' "$pkginfo" 2>/dev/null || true)
        deps_line=$(awk -F'= ' '/^depends/{print substr($0,index($0,$2))}' "$pkginfo" 2>/dev/null || true)
        if [[ -n "$deps_line" ]]; then
            # naive split on whitespace
            for d in $deps_line; do
                if [[ "$d" == "$target" ]]; then
                    # if installed, consider it dependent
                    if [[ -n "${INSTALLED[$name]:-}" ]]; then
                        _out+=("$name")
                    fi
                fi
            done
        fi
    done < <(find "${PACKAGES_DIR}" -type f -name "*.pkginfo" 2>/dev/null || true)

    # fallback: scan repo build.pkg for PKG_DEPENDS
    while IFS= read -r bp; do
        [[ -z "$bp" ]] && continue
        # source in subshell to avoid polluting env
        read -r pname deps <<< "$(bash -c "source \"$bp\" 2>/dev/null; echo \"\${PKG_NAME} \${PKG_DEPENDS[*]:-}\"" )"
        for d in $deps; do
            if [[ "$d" == "$target" ]]; then
                if [[ -n "${INSTALLED[$pname]:-}" ]]; then
                    _out+=("$pname")
                fi
            fi
        done
    done < <(find "${ADM_REPO_DIR}" -type f -name "build.pkg" 2>/dev/null || true)
}

# Get manifest path for installed package
manifest_of() {
    local pkg="$1"
    local m="${INSTALLED_DIR}/${pkg}/manifest"
    if [[ -f "$m" ]]; then
        echo "$m"
    else
        # try pkginfo based lookup via packages cache
        echo ""
    fi
}

# Backup installed package (if requested or for rollback)
backup_package() {
    local pkg="$1"
    local ts="$2"
    local srcdir="${INSTALLED_DIR}/${pkg}"
    if [[ ! -d "$srcdir" ]]; then
        echo ""
        return 1
    fi
    local out="${ROLLBACK_DIR}/${pkg}-${ts}.tar.gz"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "$out"
        return 0
    fi
    tar -C "${INSTALLED_DIR}" -czf "${out}" "${pkg}" >/dev/null 2>&1 || return 1
    echo "$out"
    return 0
}

# create json log skeleton
json_init() {
    local id="$1"
    local pf="$2"
    cat > "$pf" <<EOF
{
  "id": "${id}",
  "start": "$( _ts )",
  "package": "",
  "version": "",
  "actions": [],
  "result": null,
  "error": null,
  "end": null
}
EOF
}

json_add_action() {
    local pf="$1"
    local stage="$2"
    local status="$3"
    local detail="${4:-}"
    # append small object (naive)
    # insert before "result"
    awk -v stage="$stage" -v status="$status" -v detail="$detail" '
    BEGIN{added=0}
    /"actions": \[/ && !added { print; getline; print; print "    {\"stage\":\"" stage "\",\"status\":\"" status "\",\"detail\":\"" detail "\"},"; added=1; next }
    { print }
    ' "$pf" > "${pf}.tmp" && mv "${pf}.tmp" "$pf"
}

json_set_result() {
    local pf="$1"
    local result="$2"
    local err="${3:-}"
    # set result and end
    awk -v result="$result" -v err="$err" '
    BEGIN{done=0}
    {
      if($0 ~ /"result": null/ && done==0){
        gsub(/"result": null/,"\"result\": \"" result "\"")
      }
      if($0 ~ /"error": null/ && done==0){
        if(err!="") gsub(/"error": null/,"\"error\": \"" err "\"")
        done=1
      }
      if($0 ~ /"end": null/){ gsub(/"end": null/,"\"end\": \"" strftime("%Y-%m-%dT%H:%M:%SZ") "\"") }
      print
    }' "$pf" > "${pf}.tmp" && mv "${pf}.tmp" "$pf"
}

# remove entry from status.db (atomic)
remove_from_status_db() {
    local pkg="$1"
    if [[ ! -f "$STATUS_DB" ]]; then return 0; fi
    grep -v "^${pkg}|" "$STATUS_DB" > "${STATUS_DB}.tmp" && mv "${STATUS_DB}.tmp" "$STATUS_DB"
}

# remove files listed in manifest but transactional (move to TMP_UNINSTALL/<pkg>/)
remove_files_transactional() {
    local pkg="$1"
    local manifest="$2"
    local tmpdir="${TMP_UNINSTALL}/${pkg}"
    mkdir -p "${tmpdir}"
    local files_removed=0
    local files_failed=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        kind="${line%% *}"
        rest="${line#* }"
        if [[ "$kind" == "F" ]]; then
            fpath=$(awk '{print $2}' <<<"$line")
            if [[ -f "$fpath" ]]; then
                # keep config files if requested
                if [[ "$KEEP_CONFIG" -eq 1 && "$fpath" =~ \.(conf|cfg|ini|rc)$ ]]; then
                    continue
                fi
                # create target dir inside tmp to preserve structure
                dest="${tmpdir}${fpath}"
                mkdir -p "$(dirname "$dest")"
                if mv "$fpath" "$dest" 2>/dev/null; then
                    files_removed=$((files_removed+1))
                else
                    files_failed=$((files_failed+1))
                    echo_log ERROR "Falha ao mover $fpath"
                fi
            fi
        elif [[ "$kind" == "L" ]]; then
            lpath=$(awk '{print $2}' <<<"$line")
            if [[ -L "$lpath" ]]; then
                dest="${tmpdir}${lpath}"
                mkdir -p "$(dirname "$dest")"
                if mv "$lpath" "$dest" 2>/dev/null; then
                    files_removed=$((files_removed+1))
                else
                    files_failed=$((files_failed+1))
                    echo_log ERROR "Falha ao mover link $lpath"
                fi
            fi
        elif [[ "$kind" == "D" ]]; then
            # directories: try to remove directory if empty at later stage
            :
        fi
    done < "$manifest"

    # attempt to remove empty directories left behind
    # find directories in manifest and rmdir if empty (safety)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "${line%% *}" == "D" ]]; then
            dpath=$(awk '{print $2}' <<<"$line")
            if [[ -d "$dpath" ]]; then
                rmdir --ignore-fail-on-non-empty "$dpath" 2>/dev/null || true
            fi
        fi
    done < "$manifest"

    echo "${files_removed}:${files_failed}:${tmpdir}"
}

rollback_restore() {
    local pkg="$1"
    local backup_file="$2"
    if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
        echo "no-backup"
        return 1
    fi
    tar -C / -xzf "$backup_file" >/dev/null 2>&1 || return 1
    return 0
}

# cleanup tmp after final commit or on rollback
cleanup_tmp_for_pkg() {
    local tmpdir="$1"
    if [[ -d "$tmpdir" ]]; then
        rm -rf "$tmpdir"
    fi
}

# perform the uninstall transaction for a single package
uninstall_pkg() {
    local pkg="$1"
    local timestamp="$2"
    local __report_json="$3"   # path to json file to append details

    echo_log INFO "Starting uninstall transaction: ${pkg}"

    # prepare logs
    local lf_text
    lf_text=$(logfile_text "${pkg}-${timestamp}")
    local lf_json
    lf_json=$(logfile_json "${pkg}-${timestamp}")
    : > "$lf_text"
    json_init "${pkg}-${timestamp}" "$lf_json"

    # check installed
    if [[ -z "${INSTALLED[$pkg]:-}" ]]; then
        echo_log WARN "Pacote não instalado: ${pkg}"
        echo "{\"package\":\"${pkg}\",\"result\":\"not-installed\"}" >> "$lf_json"
        return 1
    fi

    # run pre-uninstall hooks (global and package-specific)
    if declare -f call_hook >/dev/null 2>&1; then
        echo_log INFO "Exec executando hook pre-uninstall (global/pacote)"
        call_hook "pre-uninstall" "${INSTALLED_DIR}/${pkg}" 2>>"$lf_text" || true
    fi
    json_add_action "$lf_json" "pre-uninstall" "ok" ""

    # backup installed package if requested or to enable rollback
    local backup_file=""
    if [[ $BACKUP -eq 1 || $DRY_RUN -eq 0 ]]; then
        backup_file=$(backup_package "$pkg" "$timestamp" 2>/dev/null || true)
        if [[ -n "$backup_file" ]]; then
            echo_log INFO "Backup criado: ${backup_file}"
            json_add_action "$lf_json" "backup" "ok" "${backup_file}"
        else
            echo_log WARN "Não foi possível criar backup para ${pkg}"
            json_add_action "$lf_json" "backup" "fail" ""
        fi
    fi

    # move files to tmp dir transactionally
    local manifest
    manifest=$(manifest_of "$pkg")
    if [[ -z "$manifest" || ! -f "$manifest" ]]; then
        echo_log WARN "Manifest não encontrado para ${pkg} — fallback: tentar remover diretório instalado."
        # fallback: move installed dir to tmp
        local tmpdir="${TMP_UNINSTALL}/${pkg}"
        if [[ $DRY_RUN -eq 1 ]]; then
            echo_log INFO "[DRY] mover ${INSTALLED_DIR}/${pkg} -> ${tmpdir}"
            json_add_action "$lf_json" "move" "dry-run" "${INSTALLED_DIR}/${pkg}"
        else
            mkdir -p "$(dirname "$tmpdir")"
            if mv "${INSTALLED_DIR}/${pkg}" "$tmpdir" 2>>"$lf_text"; then
                json_add_action "$lf_json" "move" "ok" "$tmpdir"
            else
                json_add_action "$lf_json" "move" "fail" ""
                echo_log ERROR "Falha ao mover ${INSTALLED_DIR}/${pkg}"
                # rollback: try restore from backup
                if [[ -n "$backup_file" ]]; then rollback_restore "$pkg" "$backup_file"; fi
                return 1
            fi
        fi
    else
        # normal path: move files listed in manifest
        if [[ $DRY_RUN -eq 1 ]]; then
            echo_log INFO "[DRY] remover conforme manifest: ${manifest}"
            json_add_action "$lf_json" "remove-manifest" "dry-run" "${manifest}"
        else
            IFS=: read -r files_removed files_failed tmpdir <<< "$(remove_files_transactional "$pkg" "$manifest")"
            json_add_action "$lf_json" "move" "ok" "$tmpdir"
            echo_log INFO "Files moved: ${files_removed}, failed: ${files_failed}"
            if [[ "$files_failed" -gt 0 ]]; then
                echo_log ERROR "Alguns arquivos não puderam ser movidos (fail=${files_failed})"
                # attempt rollback
                if [[ -n "$backup_file" ]]; then
                    echo_log INFO "Restaurando a partir do backup..."
                    rollback_restore "$pkg" "$backup_file" || echo_log ERROR "Rollback falhou"
                fi
                return 1
            fi
        fi
    fi

    # update status.db
    if [[ $DRY_RUN -eq 1 ]]; then
        echo_log INFO "[DRY] atualizar status.db removendo ${pkg}"
        json_add_action "$lf_json" "update-status" "dry-run" ""
    else
        remove_from_status_db "$pkg"
        json_add_action "$lf_json" "update-status" "ok" ""
    fi

    # run post-uninstall hooks
    if declare -f call_hook >/dev/null 2>&1; then
        call_hook "post-uninstall" "${INSTALLED_DIR}/${pkg}" 2>>"$lf_text" || true
    fi
    json_add_action "$lf_json" "post-uninstall" "ok" ""

    # commit: remove tmpdir if not needed (if backup exists we keep it in rollback dir)
    if [[ $DRY_RUN -eq 1 ]]; then
        echo_log INFO "[DRY] finalizando transação (não removendo tmp)"
    else
        # if PURGE -> remove rollback backup and temporary
        if [[ $PURGE -eq 1 ]]; then
            if [[ -d "${TMP_UNINSTALL}/${pkg}" ]]; then rm -rf "${TMP_UNINSTALL}/${pkg}"; fi
            # remove installed metadata
            rm -rf "${INSTALLED_DIR}/${pkg}" 2>/dev/null || true
            # remove backup
            if [[ -n "$backup_file" ]]; then rm -f "$backup_file" 2>/dev/null || true; fi
        else
            # leave rollback/backup and remove tmp
            if [[ -d "${TMP_UNINSTALL}/${pkg}" ]]; then rm -rf "${TMP_UNINSTALL}/${pkg}"; fi
            rm -rf "${INSTALLED_DIR}/${pkg}" 2>/dev/null || true
        fi
        json_add_action "$lf_json" "commit" "ok" ""
    fi

    json_set_result "$lf_json" "success" ""
    echo_log INFO "Uninstall completed: ${pkg}"
    # write textual log summary
    {
        echo "Uninstall: ${pkg}"
        echo "Time: $( _ts )"
        echo "Backup: ${backup_file:-none}"
        echo "Result: success"
    } >> "$lf_text"

    return 0
}

# parse CLI
_show_help() {
    cat <<EOF
uninstall.sh - ADM Package Uninstaller (transacional)

Usage:
  uninstall.sh [options] <pkg> [<pkg2> ...]
Options:
  --dry-run        : mostra o que seria feito
  --force          : ignora dependências reversas
  --purge          : remove também caches e metadados
  --deps           : remove dependências órfãs após remoção
  --keep-config    : preserva arquivos de configuração (*.conf,*.cfg,*.ini)
  --backup         : cria backup tar.gz antes de remover
  --json           : gera relatório JSON por pacote
  --no-interactive : não perguntar (assume yes)
  --rollback       : restaura último backup para <pkg>
  --help
EOF
}

# options
ARGS=()
while (( "$#" )); do
    case "$1" in
        --dry-run) DRY_RUN=1; shift;;
        --force) FORCE=1; shift;;
        --purge) PURGE=1; shift;;
        --deps) REMOVE_DEPS=1; shift;;
        --keep-config) KEEP_CONFIG=1; shift;;
        --backup) BACKUP=1; shift;;
        --json) JSON_OUT=1; shift;;
        --no-interactive) INTERACTIVE=0; shift;;
        --rollback)
            PKG_ROLLBACK="$2"
            if [[ -z "$PKG_ROLLBACK" ]]; then echo "Especifique pacote para rollback"; exit 2; fi
            # perform immediate rollback
            # locate latest rollback tar for pkg
            file=$(ls -1t "${ROLLBACK_DIR}/${PKG_ROLLBACK}-"*.tar.gz 2>/dev/null | head -n1 || true)
            if [[ -z "$file" ]]; then echo "Nenhum backup encontrado para ${PKG_ROLLBACK}"; exit 1; fi
            echo_log INFO "Restaurando backup ${file}"
            tar -C / -xzf "$file"
            echo_log INFO "Rollback concluído"
            exit 0
            ;;
        --help|-h) _show_help; exit 0;;
        *) ARGS+=("$1"); shift;;
    esac
done

if ((${#ARGS[@]} == 0)); then
    _show_help
    exit 2
fi

# main flow
load_status_db

TS=$(now_ts)
FAILED_PKGS=()
SUCCESS_PKGS=()

for target in "${ARGS[@]}"; do
    # check package installed
    if [[ -z "${INSTALLED[$target]:-}" ]]; then
        echo_log WARN "Pacote não instalado: ${target}"
        FAILED_PKGS+=("${target}")
        continue
    fi

    # find reverse dependencies
    declare -a revdeps
    find_reverse_deps "$target" revdeps

    if ((${#revdeps[@]})); then
        echo_log WARN "Dependentes encontrados para ${target}: ${revdeps[*]}"
        if [[ $FORCE -eq 0 ]]; then
            # prompt unless non-interactive or forced off
            if [[ $INTERACTIVE -eq 1 ]]; then
                echo "Pacote ${target} é requerido por: ${revdeps[*]}"
                read -r -p "Deseja continuar e remover mesmo assim? (y/N): " ans
                if [[ ! "$ans" =~ ^[Yy] ]]; then
                    echo_log INFO "Usuário cancelou remoção de ${target}"
                    FAILED_PKGS+=("${target}")
                    continue
                fi
            else
                echo_log WARN "Operação abortada para ${target} (dependentes presentes). Use --force para ignorar."
                FAILED_PKGS+=("${target}")
                continue
            fi
        else
            echo_log WARN "--force fornecido; removendo ${target} apesar de dependentes."
        fi
    fi

    # create json log if requested
    if [[ $JSON_OUT -eq 1 ]]; then
        pf_json=$(logfile_json "${target}-${TS}")
        json_init "${target}-${TS}" "$pf_json"
    else
        pf_json="/dev/null"
    fi

    # create textual log header
    lf_text=$(logfile_text "${target}-${TS}")
    {
        echo "Uninstall run: ${target}"
        echo "Start: $( _ts )"
        echo "Options: dry_run=${DRY_RUN}, force=${FORCE}, purge=${PURGE}, backup=${BACKUP}, keep_config=${KEEP_CONFIG}"
    } > "$lf_text"

    # confirm (interactive)
    if [[ $INTERACTIVE -eq 1 && $DRY_RUN -eq 0 ]]; then
        echo "Remover pacote: ${target} ?"
        read -r -p "(y/N) " yn
        if [[ ! "$yn" =~ ^[Yy] ]]; then
            echo_log INFO "Usuário cancelou remoção de ${target}"
            FAILED_PKGS+=("${target}")
            continue
        fi
    fi

    # perform uninstall
    if uninstall_pkg "$target" "$TS" "$pf_json"; then
        SUCCESS_PKGS+=("${target}")
    else
        FAILED_PKGS+=("${target}")
    fi

    # optionally remove orphan deps
    if [[ $REMOVE_DEPS -eq 1 ]]; then
        # naive: scan all installed packages and remove those that no one depends on and are not explicitly required
        # Build list of installed names
        declare -a all_installed
        for k in "${!INSTALLED[@]}"; do all_installed+=("$k"); done

        for cand in "${all_installed[@]}"; do
            # skip if it's the one we just removed
            if [[ "$cand" == "$target" ]]; then continue; fi
            # skip if other installed packages depend on it
            declare -a cand_rev
            find_reverse_deps "$cand" cand_rev
            if ((${#cand_rev[@]} == 0)); then
                # candidate orphan, ask or auto remove
                if [[ $INTERACTIVE -eq 1 ]]; then
                    read -r -p "Pacote órfão detectado: ${cand}. Remover? (y/N): " q; [[ "$q" =~ ^[Yy] ]] || continue
                fi
                if uninstall_pkg "$cand" "$TS" "$pf_json"; then
                    SUCCESS_PKGS+=("$cand")
                else
                    FAILED_PKGS+=("$cand")
                fi
            fi
        done
    fi

done

# summary
echo_log INFO "Uninstall summary: success=${#SUCCESS_PKGS[@]} failed=${#FAILED_PKGS[@]}"
if ((${#SUCCESS_PKGS[@]})); then
    echo "Sucesso:"
    for p in "${SUCCESS_PKGS[@]}"; do echo "  - $p"; done
fi
if ((${#FAILED_PKGS[@]})); then
    echo "Falharam:"
    for p in "${FAILED_PKGS[@]}"; do echo "  - $p"; done
fi

exit $(( ${#FAILED_PKGS[@]} > 0 ))
