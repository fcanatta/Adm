#!/usr/bin/env bash
# 07-remove-pkg.sh - Remove pacotes instalados e dependências órfãs,
#                    executa hooks e atualiza o banco de dados.
###############################################################################
# Detecção de modo (CLI vs sourced)
###############################################################################

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ADM_REMOVE_CLI_MODE=1
else
    ADM_REMOVE_CLI_MODE=0
fi

# Carrega env/lib se ainda não foram carregados
if [[ -z "${ADM_ENV_LOADED:-}" ]]; then
    if [[ -f /usr/src/adm/scripts/01-env.sh ]]; then
        # shellcheck disable=SC1091
        . /usr/src/adm/scripts/01-env.sh
    else
        echo "ERRO: 01-env.sh não encontrado em /usr/src/adm/scripts." >&2
        exit 1
    fi
fi

if [[ -z "${ADM_LIB_LOADED:-}" ]]; then
    if [[ -f /usr/src/adm/scripts/02-lib.sh ]]; then
        # shellcheck disable=SC1091
        . /usr/src/adm/scripts/02-lib.sh
    else
        echo "ERRO: 02-lib.sh não encontrado em /usr/src/adm/scripts." >&2
        exit 1
    fi
fi

###############################################################################
# 1. Variáveis internas / helpers DB
###############################################################################

ADM_REMOVE_STACK="${ADM_REMOVE_STACK:-}"
: "${ADM_REMOVE_AUTOREMOVE_ORPHANS:=0}"   # 0 = só lista órfãos, 1 = remove automaticamente
ADM_REMOVE_INSTALL_ROOT_DEFAULT="/"

adm_remove_pkg_db_file() {
    local name="$1"
    echo "${ADM_DB_PKG}/${name}.installed"
}

adm_remove_is_installed() {
    local name="$1"
    [[ -f "$(adm_remove_pkg_db_file "$name")" ]]
}

adm_remove_list_installed_pkgs() {
    local f
    [[ -d "${ADM_DB_PKG}" ]] || return 0
    for f in "${ADM_DB_PKG}"/*.installed; do
        [[ -e "$f" ]] || continue
        basename "${f%.installed}"
    done
}

###############################################################################
# 2. Leitura de DB de instalação e hooks
###############################################################################

# Variáveis carregadas do DB de um pacote
ADM_REMOVE_DB_NAME=""
ADM_REMOVE_DB_VERSION=""
ADM_REMOVE_DB_CATEGORY=""
ADM_REMOVE_DB_PROFILE=""
ADM_REMOVE_DB_LIBC=""
ADM_REMOVE_DB_INSTALL_ROOT=""
ADM_REMOVE_DB_METAFILE=""
ADM_REMOVE_DB_RUN_DEPS=""
ADM_REMOVE_DB_BUILD_DEPS=""
ADM_REMOVE_DB_OPT_DEPS=""

adm_remove_reset_db_vars() {
    ADM_REMOVE_DB_NAME=""
    ADM_REMOVE_DB_VERSION=""
    ADM_REMOVE_DB_CATEGORY=""
    ADM_REMOVE_DB_PROFILE=""
    ADM_REMOVE_DB_LIBC=""
    ADM_REMOVE_DB_INSTALL_ROOT=""
    ADM_REMOVE_DB_METAFILE=""
    ADM_REMOVE_DB_RUN_DEPS=""
    ADM_REMOVE_DB_BUILD_DEPS=""
    ADM_REMOVE_DB_OPT_DEPS=""
}

adm_remove_load_db_for_pkg() {
    local name="$1"
    local f
    f="$(adm_remove_pkg_db_file "$name")"

    if [[ ! -f "$f" ]]; then
        adm_error "Registro de instalação não encontrado para '${name}' em '${f}'."
        return 1
    fi

    adm_remove_reset_db_vars

    local line key val in_files=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$in_files" -eq 0 ]]; then
            # Cabeçalho até linha vazia
            [[ -z "$line" ]] && { in_files=1; continue; }

            [[ "$line" =~ ^[[:space:]]*# ]] && continue

            key="${line%%=*}"
            val="${line#*=}"
            key="${key//[[:space:]]/}"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"

            case "$key" in
                name)        ADM_REMOVE_DB_NAME="$val" ;;
                version)     ADM_REMOVE_DB_VERSION="$val" ;;
                category)    ADM_REMOVE_DB_CATEGORY="$val" ;;
                profile)     ADM_REMOVE_DB_PROFILE="$val" ;;
                libc)        ADM_REMOVE_DB_LIBC="$val" ;;
                install_root)ADM_REMOVE_DB_INSTALL_ROOT="$val" ;;
                metafile)    ADM_REMOVE_DB_METAFILE="$val" ;;
                run_deps)    ADM_REMOVE_DB_RUN_DEPS="$val" ;;
                build_deps)  ADM_REMOVE_DB_BUILD_DEPS="$val" ;;
                opt_deps)    ADM_REMOVE_DB_OPT_DEPS="$val" ;;
                *) : ;;
            esac
        else
            # Lista de arquivos – não processamos aqui
            :
        fi
    done < "$f"

    [[ -z "${ADM_REMOVE_DB_INSTALL_ROOT}" ]] && ADM_REMOVE_DB_INSTALL_ROOT="${ADM_REMOVE_INSTALL_ROOT_DEFAULT}"

    return 0
}

adm_remove_hooks_base_dir() {
    local cat="$1" name="$2"
    echo "${ADM_REPO}/${cat}/${name}/hook"
}

adm_remove_run_hook() {
    # Uso: adm_remove_run_hook <stage> <name> <category>
    local stage="$1"
    local name="$2"
    local cat="$3"

    local dir hook
    dir="$(adm_remove_hooks_base_dir "$cat" "$name")"
    hook="${dir}/${stage}.sh"

    if [[ -x "$hook" ]]; then
        adm_info "Executando hook '${stage}' para '${name}' em '${hook}'."
        ( cd "${ADM_REMOVE_DB_INSTALL_ROOT:-/}" && "$hook" ) || {
            adm_error "Hook '${stage}' falhou para '${name}'."
            return 1
        }
    fi
}

###############################################################################
# 3. Dono de arquivo e remoção segura
###############################################################################

adm_remove_file_has_other_owner() {
    # Uso: adm_remove_file_has_other_owner <arquivo_relativo> <pkg_atual>
    local rel="$1"
    local current="$2"
    local f other db root line in_files pkg

    for f in "${ADM_DB_PKG}"/*.installed; do
        [[ -e "$f" ]] || continue
        db="$(basename "$f")"
        pkg="${db%.installed}"
        [[ "$pkg" == "$current" ]] && continue

        in_files=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$in_files" -eq 0 ]]; then
                [[ -z "$line" ]] && { in_files=1; continue; }
                continue
            fi
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            if [[ "$line" == "$rel" ]]; then
                return 0
            fi
        done < "$f"
    done

    return 1
}

adm_remove_files_for_pkg() {
    local name="$1"
    local dbfile
    dbfile="$(adm_remove_pkg_db_file "$name")"

    if [[ ! -f "$dbfile" ]]; then
        adm_error "DB de pacote '${name}' não encontrado em '${dbfile}'."
        return 1
    fi

    local in_files=0 line rel full
    local root="${ADM_REMOVE_DB_INSTALL_ROOT:-/}"

    adm_info "Removendo arquivos de '${name}' (root='${root}')."

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$in_files" -eq 0 ]]; then
            [[ -z "$line" ]] && { in_files=1; continue; }
            continue
        fi

        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        rel="$line"

        # Normaliza caminho relativo com / inicial
        if [[ "$rel" != /* ]]; then
            rel="/${rel}"
        fi

        # Nunca remover "/" nem caminhos estranhos
        if [[ "$rel" == "/" ]]; then
            adm_warn "Ignorando caminho inválido '/' em DB de '${name}'."
            continue
        fi

        if adm_remove_file_has_other_owner "$rel" "$name"; then
            adm_debug "Arquivo '${rel}' também pertence a outro pacote; não será removido."
            continue
        fi

        full="${root%/}${rel}"

        if [[ -L "$full" || -f "$full" ]]; then
            adm_debug "Removendo arquivo '${full}'."
            rm -f -- "$full" 2>/dev/null || adm_warn "Falha ao remover arquivo '${full}'."
        elif [[ -d "$full" ]]; then
            # Diretórios: tentamos rmdir, se não estiver vazio falha e segue.
            rmdir "$full" 2>/dev/null || adm_debug "Diretório '${full}' não vazio ou não removível."
        else
            adm_debug "Arquivo '${full}' não existe, ignorando."
        fi
    done < "$dbfile"

    return 0
}

###############################################################################
# 4. Grafo de dependências e órfãos
###############################################################################

declare -A ADM_REMOVE_DEP_REFS   # pkg -> count de quem depende
declare -A ADM_REMOVE_PKG_EXISTS # pkg -> 1 se instalado

adm_remove_build_dep_graph() {
    ADM_REMOVE_DEP_REFS=()
    ADM_REMOVE_PKG_EXISTS=()

    local f line key val in_files=0 pkg run_deps build_deps opt_deps

    [[ -d "${ADM_DB_PKG}" ]] || return 0

    for f in "${ADM_DB_PKG}"/*.installed; do
        [[ -e "$f" ]] || continue

        pkg="$(basename "${f%.installed}")"
        ADM_REMOVE_PKG_EXISTS["$pkg"]=1

        run_deps="" build_deps="" opt_deps=""
        in_files=0

        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$in_files" -eq 0 ]]; then
                [[ -z "$line" ]] && { in_files=1; continue; }
                [[ "$line" =~ ^[[:space:]]*# ]] && continue

                key="${line%%=*}"
                val="${line#*=}"
                key="${key//[[:space:]]/}"
                val="${val#"${val%%[![:space:]]*}"}"
                val="${val%"${val##*[![:space:]]}"}"

                case "$key" in
                    run_deps)   run_deps="$val"   ;;
                    build_deps) build_deps="$val" ;;
                    opt_deps)   opt_deps="$val"   ;;
                    *) : ;;
                esac
            else
                break
            fi
        done < "$f"

        # Conta refs
        local dep
        local IFS=','

        if [[ -n "$run_deps" ]]; then
            read -r -a _arr <<< "$run_deps"
            for dep in "${_arr[@]}"; do
                [[ -z "$dep" ]] && continue
                ((ADM_REMOVE_DEP_REFS["$dep"]++))
            done
        fi

        if [[ -n "$build_deps" ]]; then
            read -r -a _arr <<< "$build_deps"
            for dep in "${_arr[@]}"; do
                [[ -z "$dep" ]] && continue
                ((ADM_REMOVE_DEP_REFS["$dep"]++))
            done
        fi

        if [[ -n "$opt_deps" ]]; then
            read -r -a _arr <<< "$opt_deps"
            for dep in "${_arr[@]}"; do
                [[ -z "$dep" ]] && continue
                ((ADM_REMOVE_DEP_REFS["$dep"]++))
            done
        fi
    done
}

adm_remove_find_orphans() {
    local pkg
    local -a orphans=()

    adm_remove_build_dep_graph

    for pkg in "${!ADM_REMOVE_PKG_EXISTS[@]}"; do
        # Se ninguém depende desse pkg, é candidato a órfão
        if [[ -z "${ADM_REMOVE_DEP_REFS[$pkg]:-}" ]]; then
            # Poderíamos proteger algumas categorias como 'sys', mas o usuário
            # quer algo agressivo/inteligente: aqui só marcamos e deixamos
            # a decisão de auto-remover no flag global.
            orphans+=("$pkg")
        fi
    done

    printf '%s\n' "${orphans[@]}"
}

adm_remove_handle_orphans() {
    local -a orphans
    local o

    mapfile -t orphans < <(adm_remove_find_orphans)

    if [[ "${#orphans[@]}" -eq 0 ]]; then
        adm_info "Nenhuma dependência órfã detectada."
        return 0
    fi

    adm_info "Pacotes órfãos detectados: ${orphans[*]}"

    if [[ "${ADM_REMOVE_AUTOREMOVE_ORPHANS}" -ne 1 ]]; then
        adm_warn "Remoção automática de órfãos DESABILITADA (ADM_REMOVE_AUTOREMOVE_ORPHANS=0)."
        adm_warn "Você pode removê-los manualmente ou habilitar auto-remover."
        return 0
    fi

    adm_info "Remoção automática de órfãos HABILITADA; removendo recursivamente."

    for o in "${orphans[@]}"; do
        # Proteção simples contra loops
        if [[ ",${ADM_REMOVE_STACK}," == *,"${o}",* ]]; then
            adm_warn "Órfão '${o}' já na stack de remoção; pulando para evitar loop."
            continue
        fi

        adm_run_with_spinner "Removendo órfão '${o}'..." adm_remove_pipeline "$o" || adm_warn "Falha ao remover órfão '${o}'."
    done
}

###############################################################################
# 5. Pipeline de remoção de um pacote
###############################################################################

adm_remove_pipeline() {
    local name="$1"

    [[ -z "$name" ]] && return 0

    if [[ ",${ADM_REMOVE_STACK}," == *,"${name}",* ]]; then
        adm_error "Ciclo de remoção detectado com pacote '${name}'."
        return 1
    fi
    ADM_REMOVE_STACK="${ADM_REMOVE_STACK},${name}"

    if ! adm_remove_is_installed "$name"; then
        adm_warn "Pacote '${name}' não está registrado como instalado; nada a remover."
        return 0
    fi

    adm_init_log "remove-${name}"
    adm_info "Iniciando remoção do pacote '${name}'."

    adm_remove_load_db_for_pkg "$name" || return 1

    local cat
    cat="${ADM_REMOVE_DB_CATEGORY:-unknown}"

    adm_remove_run_hook "pre_remove" "$name" "$cat" || return 1

    adm_run_with_spinner "Removendo arquivos de '${name}'..." \
        adm_remove_files_for_pkg "$name" || return 1

    # Remove DB de pacote
    local dbfile
    dbfile="$(adm_remove_pkg_db_file "$name")"
    if [[ -f "$dbfile" ]]; then
        rm -f "$dbfile" 2>/dev/null || adm_warn "Falha ao remover DB de '${name}' em '${dbfile}'."
    fi

    adm_remove_run_hook "post_remove" "$name" "$cat" || adm_warn "Hook post_remove falhou para '${name}'."

    adm_info "Remoção do pacote '${name}' concluída."

    # Após remover um pacote, recalcula órfãos e trata conforme configuração
    adm_remove_handle_orphans

    return 0
}

###############################################################################
# 6. CLI
###############################################################################

adm_remove_usage() {
    cat <<EOF
Uso: 07-remove-pkg.sh [opções] <pacote> [pacote2 pacote3 ...]

Opções:
  --with-orphans     - remove automaticamente pacotes órfãos após cada remoção
  --no-orphans       - não remove órfãos automaticamente (apenas lista) [padrão]
  -h, --help         - mostra esta ajuda

A remoção:
  - Lê o DB de instalação em: ${ADM_DB_PKG}/<nome>.installed
  - Executa hooks de pre_remove/post_remove se existirem em:
        ${ADM_REPO}/<categoria>/<nome>/hook/
  - Remove apenas arquivos que não pertençam a outros pacotes
  - Atualiza o DB, e em seguida detecta dependências órfãs
EOF
}

adm_remove_main() {
    adm_enable_strict_mode

    local with_orphans=""
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-orphans)
                with_orphans="1"
                shift
                ;;
            --no-orphans)
                with_orphans="0"
                shift
                ;;
            -h|--help)
                adm_remove_usage
                exit 0
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    if [[ "${#args[@]}" -eq 0 ]]; then
        adm_remove_usage
        exit 1
    fi

    if [[ -n "$with_orphans" ]]; then
        ADM_REMOVE_AUTOREMOVE_ORPHANS="$with_orphans"
    fi

    local pkg
    for pkg in "${args[@]}"; do
        adm_run_with_spinner "Removendo pacote '${pkg}'..." adm_remove_pipeline "$pkg" || {
            adm_error "Falha ao remover '${pkg}'."
            exit 1
        }
    done
}

if [[ "$ADM_REMOVE_CLI_MODE" -eq 1 ]]; then
    adm_remove_main "$@"
fi
