#!/usr/bin/env bash
#=============================================================
# patch.sh — Sistema de aplicação de patches do ADM Build System
#-------------------------------------------------------------
# Funções:
#   - Detecta e aplica automaticamente patches .patch e .diff
#   - Pode ser usado manualmente (--apply, --verify)
#   - Gera logs e mostra progresso visual
#=============================================================

set -o pipefail

[[ -n "${ADM_PATCH_SH_LOADED}" ]] && return
ADM_PATCH_SH_LOADED=1

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
PATCH_LOG_DIR="${ADM_LOG_DIR:-/usr/src/adm/logs}"
PATCH_LOG_FILE="${PATCH_LOG_DIR}/patch.log"
PATCH_TMP_DIR="${ADM_TMP_DIR:-/usr/src/adm/tmp}"

ensure_dir "$PATCH_LOG_DIR"
ensure_dir "$PATCH_TMP_DIR"

#-------------------------------------------------------------
#  Aplicar patch individual
#-------------------------------------------------------------
apply_patch_file() {
    local patch_file="$1"
    local target_dir="$2"
    local pkg_label="$3"

    log_info "Aplicando patch: $(basename "$patch_file") em ${pkg_label}"
    ui_draw_progress "${pkg_label}" "patch" 30 0

    if patch -d "$target_dir" -Np1 < "$patch_file" >>"$PATCH_LOG_FILE" 2>&1; then
        log_success "Patch aplicado: $(basename "$patch_file")"
        ui_draw_progress "${pkg_label}" "patch" 100 1
        return 0
    else
        log_error "Falha ao aplicar patch: $(basename "$patch_file")"
        echo "FAIL|${pkg_label}|$(basename "$patch_file")" >> "$PATCH_LOG_FILE"
        ui_draw_progress "${pkg_label}" "patch" 100 1
        return 1
    fi
}

#-------------------------------------------------------------
#  Detectar patches automaticamente (.patch e .diff)
#-------------------------------------------------------------
detect_patches() {
    local pkg_dir="$1"
    local patch_dir="${pkg_dir}/patches"

    if [[ ! -d "$patch_dir" ]]; then
        log_warn "Nenhum diretório de patches encontrado: ${patch_dir}"
        return 1
    fi

    mapfile -t patches < <(find "$patch_dir" -type f \( -name "*.patch" -o -name "*.diff" \) | sort)
    if [[ ${#patches[@]} -eq 0 ]]; then
        log_info "Nenhum patch a aplicar em ${pkg_dir##*/}"
        return 1
    fi

    echo "${patches[@]}"
}

#-------------------------------------------------------------
#  Aplicar todos os patches automaticamente
#-------------------------------------------------------------
apply_patches() {
    local pkg_dir="$1"
    local src_dir="$2"

    local build_file="${pkg_dir}/build.pkg"
    [[ ! -f "$build_file" ]] && abort_build "Arquivo ausente: ${build_file}"

    source "$build_file"
    local pkg_label="${PKG_NAME}-${PKG_VERSION}"

    print_section "Aplicando patches em ${pkg_label}"
    ui_draw_header "${pkg_label}" "patch"

    local patches
    patches=($(detect_patches "$pkg_dir"))
    [[ ${#patches[@]} -eq 0 ]] && {
        log_info "Nenhum patch encontrado para ${pkg_label}"
        return 0
    }

    for patch_file in "${patches[@]}"; do
        apply_patch_file "$patch_file" "$src_dir" "$pkg_label" || {
            log_error "Erro ao aplicar ${patch_file}"
            return 1
        }
    done

    log_success "Todos os patches aplicados com sucesso em ${pkg_label}"
}

#-------------------------------------------------------------
#  Verificar patches disponíveis
#-------------------------------------------------------------
verify_patches() {
    local pkg_dir="$1"
    local build_file="${pkg_dir}/build.pkg"
    [[ ! -f "$build_file" ]] && abort_build "Arquivo ausente: ${build_file}"

    source "$build_file"
    local patch_dir="${pkg_dir}/patches"
    local pkg_label="${PKG_NAME}-${PKG_VERSION}"

    print_section "Verificando patches de ${pkg_label}"
    ui_draw_header "${pkg_label}" "patch-verify"

    local patches
    patches=($(detect_patches "$pkg_dir"))

    if [[ ${#patches[@]} -eq 0 ]]; then
        log_info "Nenhum patch encontrado para ${pkg_label}"
        return 0
    fi

    log_success "Foram detectados ${#patches[@]} patches em ${pkg_label}:"
    for p in "${patches[@]}"; do
        echo "  • $(basename "$p")"
    done
}

#-------------------------------------------------------------
#  Execução principal
#-------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    log_init
    case "$1" in
        --apply)
            pkg_dir="$2"; src_dir="$3"
            [[ -z "$pkg_dir" || -z "$src_dir" ]] && abort_build "Uso: patch.sh --apply <pkg_dir> <src_dir>"
            apply_patches "$pkg_dir" "$src_dir"
            ;;
        --verify)
            pkg_dir="$2"
            [[ -z "$pkg_dir" ]] && abort_build "Uso: patch.sh --verify <pkg_dir>"
            verify_patches "$pkg_dir"
            ;;
        --test)
            print_section "Teste do patch.sh"
            pkg_dir="/usr/src/adm/repo/core/zlib"
            src_dir="/usr/src/adm/build/zlib-1.3.1"
            apply_patches "$pkg_dir" "$src_dir"
            ;;
        *)
            echo "Uso: patch.sh [--apply <pkg_dir> <src_dir>] [--verify <pkg_dir>] [--test]"
            ;;
    esac
    log_close
fi
