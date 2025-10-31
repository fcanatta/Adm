#!/usr/bin/env bash
#=============================================================
# fetch.sh — Gerenciador de fontes do ADM Build System
#-------------------------------------------------------------
# Modos:
#   fetch.sh sync        -> sincroniza repositórios listados em repo.list
#   fetch.sh            -> varre repo/ local e baixa sources definidos em build.pkg
#   fetch.sh --test     -> sincroniza e processa (modo de demonstração)
#
# Repositório:
#   repo.list format:
#     <type> <url_or_path> <group>
#     ex:
#       git https://github.com/fcanatta/core-repo.git core
#       rsync rsync://mirror.example.org/sources/ net
#       ftp ftp://ftp.gnu.org/gnu gnu
#       dir /srv/local-repo local
#=============================================================

set -o pipefail

# Allow running directly or via source; if sourced, skip main execution.
[[ -n "${ADM_FETCH_SH_LOADED}" ]] && return
ADM_FETCH_SH_LOADED=1

#-------------------------------------------------------------
#  Dependências mínimas (env, logs, utils, ui)
#-------------------------------------------------------------
# env.sh must set ADM_ROOT and ADM_CACHE_SOURCES, ADM_LOG_DIR etc.
if [[ -f "/usr/src/adm/scripts/env.sh" ]]; then
    source /usr/src/adm/scripts/env.sh
else
    echo "env.sh não encontrado em /usr/src/adm/scripts/ — execute setup primeiro."
    exit 1
fi

# load other modules; if not present, warn/exit
for mod in log.sh utils.sh ui.sh; do
    if [[ -f "${ADM_ROOT}/scripts/${mod}" ]]; then
        # shellcheck source=/usr/src/adm/scripts/log.sh
        source "${ADM_ROOT}/scripts/${mod}"
    else
        echo "Módulo faltando: ${ADM_ROOT}/scripts/${mod}. Execute antes."
        exit 1
    fi
done

#-------------------------------------------------------------
#  Configuração
#-------------------------------------------------------------
FETCH_REPO_DIR="${ADM_ROOT}/repo"
FETCH_REPO_LIST="${ADM_ROOT}/repo.list"
FETCH_CACHE_DIR="${ADM_CACHE_SOURCES:-${ADM_ROOT}/cache/sources}"
FETCH_TIMEOUT=60
FETCH_RETRY=3

# Ensure cache dir exists
ensure_dir "$FETCH_CACHE_DIR"

#-------------------------------------------------------------
#  Helpers internos
#-------------------------------------------------------------
log_and_ui_header() {
    local title="$1"
    ui_draw_header "$title" "fetch"
    print_section "$title"
}

# Read build.pkg from a package directory and validate essential vars.
load_build_metadata() {
    local pkg_dir="$1"
    local build_file="${pkg_dir}/build.pkg"

    if [[ ! -f "$build_file" ]]; then
        log_error "Arquivo build.pkg não encontrado em: ${pkg_dir}"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$build_file"

    # Required variables: PKG_NAME, PKG_VERSION, PKG_URL
    if [[ -z "${PKG_NAME:-}" || -z "${PKG_VERSION:-}" || -z "${PKG_URL:-}" ]]; then
        log_error "Metadados incompletos em ${build_file}. PKG_NAME/PKG_VERSION/PKG_URL necessários."
        return 2
    fi

    return 0
}

# Check cache and verify using PKG_SHA256 if present
fetch_check_cache() {
    local file_name="$1"
    local pkg_sha="$2"
    local dest="${FETCH_CACHE_DIR}/${file_name}"

    if [[ -f "$dest" ]]; then
        log_info "Encontrado no cache: ${file_name}"
        if [[ -n "${pkg_sha:-}" ]]; then
            if verify_checksum "$dest" "$pkg_sha"; then
                return 0
            else
                log_warn "Checksum inválido no cache para ${file_name}, removendo e baixando novamente."
                rm -f "$dest"
                return 1
            fi
        else
            log_info "Nenhum checksum definido, usando arquivo em cache: ${file_name}"
            return 0
        fi
    fi
    return 1
}

# Generic download with retries (uses wget). Returns 0 on success.
fetch_download_url() {
    local url="$1"
    local dest="$2"
    local pkg_label="$3"
    local attempt

    check_command wget || { log_error "wget não disponível"; return 2; }

    for ((attempt=1; attempt<=FETCH_RETRY; attempt++)); do
        log_info "Baixando ${pkg_label} (tentativa ${attempt}/${FETCH_RETRY}) -> ${url}"
        # show UI progress (approximation)
        ui_draw_progress "${pkg_label}" "fetch" "$((attempt*100/ FETCH_RETRY))" "$((attempt*2))" 2>/dev/null || true

        if wget --timeout="${FETCH_TIMEOUT}" -q -O "${dest}" "${url}"; then
            log_success "Download concluído: ${pkg_label}"
            return 0
        else
            log_warn "Tentativa ${attempt}/${FETCH_RETRY} falhou para ${pkg_label}"
            sleep 2
        fi
    done

    log_error "Falha ao baixar ${pkg_label} depois de ${FETCH_RETRY} tentativas."
    return 1
}

# Try to download and validate; supports simple URL fallback by replacing host if mirror provided
fetch_package_from_metadata() {
    local pkg_dir="$1"
    if ! load_build_metadata "$pkg_dir"; then
        return 1
    fi

    local file_name="${PKG_URL##*/}"
    local dest="${FETCH_CACHE_DIR}/${file_name}"
    local pkg_label="${PKG_NAME}-${PKG_VERSION}"

    log_and_ui_header "Processando ${pkg_label}"
    ensure_dir "$FETCH_CACHE_DIR"

    # If present and valid in cache, skip download
    if fetch_check_cache "$file_name" "${PKG_SHA256:-}"; then
        log_success "${pkg_label} encontrado no cache e válido — pulando download."
        return 0
    fi

    # Try direct URL download
    if fetch_download_url "${PKG_URL}" "$dest" "$pkg_label"; then
        if [[ -n "${PKG_SHA256:-}" ]]; then
            if ! verify_checksum "$dest" "${PKG_SHA256}"; then
                log_error "Checksum inválido para ${pkg_label}"
                rm -f "$dest"
                return 2
            fi
        fi
        log_success "Fetch concluído: ${pkg_label}"
        return 0
    fi

    # If direct failed, attempt simple fallback strategies (try ftp/http variants or mirrors if declared)
    # Example: if PKG_URL uses http(s) and there is an equivalent ftp, try substituting or vice-versa.
    # This is conservative: we attempt simple host swap patterns (user can extend).
    if [[ "${PKG_URL}" =~ ^https?:// ]]; then
        local alt="${PKG_URL/https:\/\//ftp:\/\/}"
        log_warn "Tentando fallback: ${alt}"
        if fetch_download_url "$alt" "$dest" "$pkg_label"; then
            [[ -n "${PKG_SHA256:-}" ]] && verify_checksum "$dest" "${PKG_SHA256}" || true
            return 0
        fi
    fi

    log_error "Não foi possível baixar ${pkg_label} a partir de ${PKG_URL}"
    return 3
}

#-------------------------------------------------------------
#  Repo sync: reads repo.list and synchronizes each entry
#  This function runs only when called with 'sync'
#-------------------------------------------------------------
sync_repositories() {
    print_section "Sincronizando repositórios (repo.list)"
    if [[ ! -f "${FETCH_REPO_LIST}" ]]; then
        log_error "Arquivo repo.list não encontrado em ${FETCH_REPO_LIST}"
        return 1
    fi

    while read -r type url group; do
        # skip empty or comment lines
        [[ -z "${type}" || "${type:0:1}" == "#" ]] && continue
        if [[ -z "${group}" ]]; then
            log_warn "Linha inválida em repo.list: '${type} ${url} ${group}' — pulando"
            continue
        fi

        local target="${FETCH_REPO_DIR}/${group}"
        ensure_dir "${target}"

        ui_draw_header "repo-sync" "${group}"
        case "${type}" in
            git)
                check_command git || { log_error "git ausente, não é possível sincronizar ${group}"; continue; }
                if [[ -d "${target}/.git" ]]; then
                    log_info "Atualizando repositório Git: ${group}"
                    if ! git -C "${target}" pull --quiet; then
                        log_warn "Pull falhou em ${group}, re-clonando..."
                        rm -rf "${target}"
                        git clone --depth=1 "${url}" "${target}" || {
                            log_error "Falha ao clonar ${url} para ${target}"
                            continue
                        }
                    fi
                else
                    log_info "Clonando repositório Git: ${group}"
                    if ! git clone --depth=1 "${url}" "${target}"; then
                        log_error "Falha ao clonar ${url} para ${target}"
                        continue
                    fi
                fi
                ;;
            rsync)
                check_command rsync || { log_error "rsync ausente, não é possível sincronizar ${group}"; continue; }
                log_info "Sincronizando via rsync: ${group}"
                if ! rsync -az --delete "${url}" "${target}/"; then
                    log_warn "rsync falhou para ${group}"
                fi
                ;;
            ftp|http|https)
                check_command wget || { log_error "wget ausente, não é possível baixar snapshot para ${group}"; continue; }
                log_info "Baixando snapshot via wget para ${group}"
                # Use recursive download into target; users should structure remote to match expected layout.
                if ! wget -q -r -np -nH -P "${target}" "${url}"; then
                    log_warn "wget snapshot falhou para ${url}"
                fi
                ;;
            dir)
                if [[ ! -d "${url}" ]]; then
                    log_warn "Diretório fonte não encontrado: ${url}"
                    continue
                fi
                log_info "Copiando repositório local ${url} → ${target}"
                if ! cp -a "${url}/." "${target}/"; then
                    log_warn "Cópia do diretório ${url} falhou"
                fi
                ;;
            *)
                log_warn "Tipo de repositório não suportado: ${type}"
                ;;
        esac

        log_success "Repositório sincronizado: ${group}"
    done < "${FETCH_REPO_LIST}"

    log_success "Sincronização de repositórios concluída."
    return 0
}

#-------------------------------------------------------------
#  Iterate over local repo tree and fetch packages
#  Default behavior (no args) scans repo/ and processes build.pkg files
#-------------------------------------------------------------
fetch_all_local_packages() {
    print_section "Procurando build.pkg em ${FETCH_REPO_DIR}"
    # find package directories that contain build.pkg
    mapfile -t pkg_dirs < <(find "${FETCH_REPO_DIR}" -type f -name "build.pkg" -print0 | xargs -0 -n1 dirname 2>/dev/null || true)

    if [[ ${#pkg_dirs[@]} -eq 0 ]]; then
        log_warn "Nenhum build.pkg encontrado em ${FETCH_REPO_DIR}"
        return 0
    fi

    for pkg_dir in "${pkg_dirs[@]}"; do
        log_info "Processando pacote em: ${pkg_dir}"
        if ! fetch_package_from_metadata "${pkg_dir}"; then
            log_warn "Falha ao processar pacote: ${pkg_dir} (continuando com próximos)"
            continue
        fi
    done

    log_success "Processamento dos pacotes locais concluído."
    return 0
}

#-------------------------------------------------------------
#  Main: CLI handling
#-------------------------------------------------------------
_show_help() {
    cat <<EOF
fetch.sh - gerenciador de fontes ADM

Uso:
  fetch.sh sync        # sincroniza repositórios listados em ${FETCH_REPO_LIST}
  fetch.sh             # varre ${FETCH_REPO_DIR} e baixa sources conforme build.pkg
  fetch.sh --test      # executa sync (se repo.list existir) + processa pacotes (modo demonstração)
  fetch.sh --help      # mostra esta ajuda
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # script being executed
    case "${1:-}" in
        sync)
            log_init
            sync_repositories
            log_close
            ;;
        --test)
            log_init
            # if repo.list exists, do sync first; otherwise, skip sync
            [[ -f "${FETCH_REPO_LIST}" ]] && sync_repositories || log_info "repo.list não encontrado: pulando sync"
            fetch_all_local_packages
            log_close
            ;;
        --help|-h)
            _show_help
            ;;
        "" )
            log_init
            fetch_all_local_packages
            log_close
            ;;
        *)
            echo "Opção inválida: ${1}"
            _show_help
            exit 2
            ;;
    esac
fi
