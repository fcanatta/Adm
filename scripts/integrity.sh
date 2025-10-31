#!/usr/bin/env bash
#=============================================================
# integrity.sh — Verificação de integridade do ADM Build System
#-------------------------------------------------------------
# Funções:
#  - Valida SHA256 de todos os sources em cache
#  - Gera relatórios detalhados e resumo visual
#  - Modo --fix remove automaticamente fontes corrompidas
#=============================================================

set -o pipefail

[[ -n "${ADM_INTEGRITY_SH_LOADED}" ]] && return
ADM_INTEGRITY_SH_LOADED=1

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
INTEGRITY_CACHE_DIR="${ADM_CACHE_SOURCES:-/usr/src/adm/cache/sources}"
INTEGRITY_REPO_DIR="${ADM_REPO_DIR:-/usr/src/adm/repo}"
INTEGRITY_LOG_DIR="${ADM_LOG_DIR:-/usr/src/adm/logs}"
INTEGRITY_REPORT="${INTEGRITY_LOG_DIR}/integrity-report.log"
INTEGRITY_SUMMARY="${INTEGRITY_LOG_DIR}/integrity-summary.log"

ensure_dir "$INTEGRITY_LOG_DIR"
ensure_dir "$INTEGRITY_CACHE_DIR"

#-------------------------------------------------------------
#  Verificar integridade de um pacote individual
#-------------------------------------------------------------
check_package_integrity() {
    local pkg_dir="$1"
    local build_file="${pkg_dir}/build.pkg"

    [[ ! -f "$build_file" ]] && {
        log_error "Arquivo ausente: ${build_file}"
        echo "MISSING|${pkg_dir}" >> "$INTEGRITY_REPORT"
        return 2
    }

    # shellcheck disable=SC1090
    source "$build_file"

    local file_name="${PKG_URL##*/}"
    local file_path="${INTEGRITY_CACHE_DIR}/${file_name}"

    # Cabeçalho visual
    ui_draw_header "integrity" "${PKG_NAME}-${PKG_VERSION}"
    ui_draw_progress "${PKG_NAME}" "verificando" 10 0

    # Verificação de existência
    if [[ ! -f "$file_path" ]]; then
        log_error "Fonte ausente: ${file_name}"
        echo "MISSING|${PKG_NAME}|${PKG_VERSION}|${file_name}" >> "$INTEGRITY_REPORT"
        return 2
    fi

    # Verificação de checksum
    if [[ -z "$PKG_SHA256" ]]; then
        log_warn "Sem checksum definido para ${PKG_NAME}"
        echo "UNCHECKED|${PKG_NAME}|${PKG_VERSION}|${file_name}" >> "$INTEGRITY_REPORT"
        ui_draw_progress "${PKG_NAME}" "verificando" 100 1
        return 0
    fi

    ui_draw_progress "${PKG_NAME}" "verificando" 60 1
    local calc_sha
    calc_sha=$(sha256sum "$file_path" | awk '{print $1}')

    if [[ "$calc_sha" == "$PKG_SHA256" ]]; then
        log_success "Integridade OK: ${PKG_NAME}-${PKG_VERSION}"
        echo "OK|${PKG_NAME}|${PKG_VERSION}|${file_name}" >> "$INTEGRITY_REPORT"
        ui_draw_progress "${PKG_NAME}" "verificando" 100 1
        return 0
    else
        log_error "Checksum incorreto: ${PKG_NAME}-${PKG_VERSION}"
        echo "FAIL|${PKG_NAME}|${PKG_VERSION}|${file_name}" >> "$INTEGRITY_REPORT"
        ui_draw_progress "${PKG_NAME}" "verificando" 100 1
        return 1
    fi
}

#-------------------------------------------------------------
#  Verificar integridade de todos os pacotes
#-------------------------------------------------------------
check_all_packages() {
    print_section "Verificando integridade dos pacotes"
    : > "$INTEGRITY_REPORT"

    local pkg_dirs=($(find "$INTEGRITY_REPO_DIR" -type f -name "build.pkg" -exec dirname {} \;))
    local total=${#pkg_dirs[@]}
    local ok=0 fail=0 missing=0 unchecked=0

    for pkg_dir in "${pkg_dirs[@]}"; do
        check_package_integrity "$pkg_dir"
        case $? in
            0)
                grep -q "^UNCHECKED" <<< "$(tail -n1 "$INTEGRITY_REPORT")" && ((unchecked++)) || ((ok++))
                ;;
            1) ((fail++));;
            2) ((missing++));;
        esac
    done

    echo "TOTAL|$total|OK:$ok|FAIL:$fail|MISSING:$missing|UNCHECKED:$unchecked" >> "$INTEGRITY_REPORT"
    generate_report "$ok" "$fail" "$missing" "$unchecked" "$total"
}

#-------------------------------------------------------------
#  Gerar relatório e resumo visual
#-------------------------------------------------------------
generate_report() {
    local ok=$1 fail=$2 missing=$3 unchecked=$4 total=$5

    print_section "Resumo de integridade"
    {
        echo "================================================="
        echo "Relatório de Integridade - $(date)"
        echo "Pacotes verificados: $total"
        echo "Válidos: $ok"
        echo "Corrompidos: $fail"
        echo "Ausentes: $missing"
        echo "Sem Checksum: $unchecked"
        echo "================================================="
    } > "$INTEGRITY_SUMMARY"

    echo -e "\n${GREEN}✔️  Válidos: ${ok}${RESET}"
    echo -e "${RED}✖️  Corrompidos: ${fail}${RESET}"
    echo -e "${YELLOW}❓  Ausentes: ${missing}${RESET}"
    echo -e "${BLUE}⚙️  Sem Checksum: ${unchecked}${RESET}"
    echo -e "\n🗂  Relatório completo: ${INTEGRITY_REPORT}"
    echo -e "📄  Resumo: ${INTEGRITY_SUMMARY}\n"

    log_info "Resumo salvo em ${INTEGRITY_SUMMARY}"
}

#-------------------------------------------------------------
#  Remover fontes corrompidas (modo --fix)
#-------------------------------------------------------------
fix_corrupted_sources() {
    print_section "Removendo fontes corrompidas"
    grep "^FAIL" "$INTEGRITY_REPORT" | while IFS="|" read -r _ name version file; do
        local path="${INTEGRITY_CACHE_DIR}/${file}"
        if [[ -f "$path" ]]; then
            log_warn "Removendo arquivo corrompido: ${file}"
            rm -f "$path"
        fi
    done
    log_success "Arquivos inválidos removidos. Reexecute fetch.sh para baixá-los novamente."
}

#-------------------------------------------------------------
#  Execução principal
#-------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    log_init
    case "$1" in
        --fix)
            check_all_packages
            fix_corrupted_sources
            ;;
        --report)
            check_all_packages
            ;;
        --test)
            print_section "Teste de integridade (simulação)"
            check_all_packages
            ;;
        *)
            check_all_packages
            ;;
    esac
    log_close
fi
