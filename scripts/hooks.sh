#!/usr/bin/env bash
#=============================================================
# hooks.sh — Sistema de Hooks do ADM Build System
#-------------------------------------------------------------
# Permite executar scripts personalizados em cada fase do ciclo:
#   pre/post-fetch, patch, build, install, uninstall, clean
#=============================================================

set -o pipefail
[[ -n "${ADM_HOOKS_SH_LOADED}" ]] && return
ADM_HOOKS_SH_LOADED=1

#-------------------------------------------------------------
#  Segurança
#-------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" && ! -f "/usr/src/adm/scripts/env.sh" ]]; then
    echo "❌ Este script deve ser executado dentro do ambiente ADM."
    exit 1
fi

#-------------------------------------------------------------
#  Dependências
#-------------------------------------------------------------
source /usr/src/adm/scripts/env.sh
source /usr/src/adm/scripts/log.sh
source /usr/src/adm/scripts/utils.sh
source /usr/src/adm/scripts/ui.sh

#-------------------------------------------------------------
#  Configuração
#-------------------------------------------------------------
HOOKS_GLOBAL_DIR="${ADM_ROOT}/hooks.d"
HOOKS_LOG_DIR="${ADM_LOG_DIR}/hooks"
HOOKS_LOG_FILE="${HOOKS_LOG_DIR}/hooks.log"
HOOKS_TIMEOUT=60

ensure_dir "$HOOKS_LOG_DIR"
ensure_dir "$HOOKS_GLOBAL_DIR"

#-------------------------------------------------------------
#  Executar hook individual com log e spinner
#-------------------------------------------------------------
run_hook_file() {
    local hook_file="$1"
    local phase="$2"
    local pkg_label="$3"

    [[ ! -x "$hook_file" ]] && chmod +x "$hook_file"
    log_info "Executando hook: $(basename "$hook_file") [${phase}]"
    ui_draw_progress "${pkg_label}" "${phase}" 25 0

    timeout "${HOOKS_TIMEOUT}" bash "$hook_file" >>"$HOOKS_LOG_FILE" 2>&1
    local status=$?

    if [[ $status -eq 0 ]]; then
        log_success "Hook concluído: $(basename "$hook_file")"
        ui_draw_progress "${pkg_label}" "${phase}" 100 1
        return 0
    else
        log_error "Hook falhou: $(basename "$hook_file") (status $status)"
        echo "FAIL|${pkg_label}|${phase}|${hook_file}" >>"$HOOKS_LOG_FILE"
        return 1
    fi
}

#-------------------------------------------------------------
#  Executar todos os hooks de uma fase (globais + locais)
#-------------------------------------------------------------
call_hook() {
    local phase="$1"
    local pkg_dir="$2"
    local build_file="${pkg_dir}/build.pkg"
    local pkg_label="system"

    [[ -f "$build_file" ]] && source "$build_file" && pkg_label="${PKG_NAME}-${PKG_VERSION}"

    print_section "Executando hooks (${phase})"
    ui_draw_header "${pkg_label}" "${phase}"

    local hook_files=()

    # Hooks globais
    mapfile -t global_hooks < <(find "$HOOKS_GLOBAL_DIR" -maxdepth 1 -type f -name "${phase}.sh" 2>/dev/null)
    hook_files+=("${global_hooks[@]}")

    # Hooks locais do pacote
    local local_hook_dir="${pkg_dir}/hooks"
    if [[ -d "$local_hook_dir" ]]; then
        mapfile -t local_hooks < <(find "$local_hook_dir" -maxdepth 1 -type f -name "${phase}.sh" 2>/dev/null)
        hook_files+=("${local_hooks[@]}")
    fi

    # Nenhum hook encontrado
    if [[ ${#hook_files[@]} -eq 0 ]]; then
        log_info "Nenhum hook encontrado para ${phase}"
        return 0
    fi

    for hook_file in "${hook_files[@]}"; do
        run_hook_file "$hook_file" "$phase" "$pkg_label" || return 1
    done

    log_success "Todos os hooks (${phase}) executados com sucesso."
}

#-------------------------------------------------------------
#  Listar hooks globais e locais
#-------------------------------------------------------------
list_hooks() {
    print_section "Hooks disponíveis"
    echo -e "🔧 Globais em ${HOOKS_GLOBAL_DIR}:"
    find "$HOOKS_GLOBAL_DIR" -type f -name "*.sh" -printf "  • %P\n" 2>/dev/null || true
    echo -e "\n📦 Locais em ${ADM_REPO_DIR}:"
    find "$ADM_REPO_DIR" -type f -path "*/hooks/*.sh" -printf "  • %P\n" 2>/dev/null || true
}

#-------------------------------------------------------------
#  Lista das fases reconhecidas
#-------------------------------------------------------------
list_supported_phases() {
    echo "Fases suportadas:"
    echo "  pre-fetch, post-fetch"
    echo "  pre-patch, post-patch"
    echo "  pre-build, post-build"
    echo "  pre-install, post-install"
    echo "  pre-uninstall, post-uninstall"
    echo "  pre-clean, post-clean"
}

#-------------------------------------------------------------
#  Execução principal
#-------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    log_init
    case "$1" in
        --list)
            list_hooks
            ;;
        --run)
            phase="$2"; pkg_dir="$3"
            [[ -z "$phase" || -z "$pkg_dir" ]] && abort_build "Uso: hooks.sh --run <phase> <pkg_dir>"
            call_hook "$phase" "$pkg_dir"
            ;;
        --phases)
            list_supported_phases
            ;;
        --test)
            print_section "Teste do hooks.sh"
            call_hook "pre-uninstall" "/usr/src/adm/repo/core/zlib"
            ;;
        *)
            echo "Uso: hooks.sh [--list] [--phases] [--run <phase> <pkg_dir>] [--test]"
            ;;
    esac
    log_close
fi
