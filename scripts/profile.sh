#!/usr/bin/env bash
#=============================================================
# profile.sh — Gerenciador de perfis do ADM Build System
#-------------------------------------------------------------
# Comandos:
#   profile.sh list
#   profile.sh create <name>
#   profile.sh activate <name>
#   profile.sh show <name>
#   profile.sh current
#   profile.sh edit <name>
#   profile.sh delete <name>
#   profile.sh export [--env-file FILE]
#   profile.sh check <name>
#   profile.sh menu
#
# Recursos:
#  - backup automático do perfil anterior
#  - autodetecção de CPU/toolchain/nproc
#  - validação de perfis
#  - exporta VARS para state/current.env e symlink state/current.profile
#  - hooks: pre-profile, post-profile
#  - logs em logs/profile/changes.log
#=============================================================

set -o errexit
set -o nounset
set -o pipefail

[[ -n "${ADM_PROFILE_SH_LOADED:-}" ]] && return 0
ADM_PROFILE_SH_LOADED=1

#-------------------------------------------------------------
# Safety: must run inside ADM
#-------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" && ! -f "/usr/src/adm/scripts/env.sh" ]]; then
    echo "❌ Este script deve ser executado dentro do ambiente ADM."
    exit 1
fi

#-------------------------------------------------------------
# Load helpers (optional; abort gracefully if missing)
#-------------------------------------------------------------
source /usr/src/adm/scripts/env.sh
# log.sh, ui.sh and hooks.sh are optional but enhance output
source /usr/src/adm/scripts/log.sh 2>/dev/null || true
source /usr/src/adm/scripts/ui.sh  2>/dev/null || true
source /usr/src/adm/scripts/hooks.sh 2>/dev/null || true
source /usr/src/adm/scripts/utils.sh 2>/dev/null || true

#-------------------------------------------------------------
# Paths & defaults
#-------------------------------------------------------------
PROFILES_DIR="${ADM_ROOT}/profiles"
STATE_DIR="${ADM_ROOT}/state"
CURRENT_LINK="${STATE_DIR}/current.profile"
CURRENT_ENV="${STATE_DIR}/current.env"
BACKUP_FILE="${STATE_DIR}/profile.backup"
LOG_DIR="${ADM_LOG_DIR}/profile"
CHANGES_LOG="${LOG_DIR}/changes.log"

# Ensure directories exist (use ensure_dir if available)
mkdir -p "${PROFILES_DIR}" "${STATE_DIR}" "${LOG_DIR}"

# Editor
: "${EDITOR:=${VISUAL:-${EDITOR:-vi}}}"

#-------------------------------------------------------------
# Helpers
#-------------------------------------------------------------
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log_change() {
    local msg="$*"
    printf "%s %s\n" "$(timestamp)" "$msg" >> "${CHANGES_LOG}"
    # If log.sh is available, also use it
    if declare -f log_info >/dev/null 2>&1; then
        log_info "$msg"
    fi
}

ui_header() {
    if declare -f ui_draw_header >/dev/null 2>&1; then
        ui_draw_header "profile" "$1"
    else
        printf "\n=== %s ===\n" "$1"
    fi
}

profile_path() { printf "%s/%s.profile" "${PROFILES_DIR}" "$1"; }
profile_exists() { [[ -f "$(profile_path "$1")" ]]; }
list_profiles_raw() {
    find "${PROFILES_DIR}" -maxdepth 1 -type f -name "*.profile" -printf "%f\n" 2>/dev/null | sed 's/\.profile$//' | sort
}

require_profile_name() {
    if [[ -z "${1:-}" ]]; then
        echo "Uso: $0 <nome-do-perfil>"
        exit 2
    fi
}

# safe source profile into subshell and print exported vars
dump_profile_exports() {
    local pfile="$1"
    # read variables we care about and print export lines (sanitized)
    bash -c "set -o errexit; source \"$pfile\" >/dev/null 2>&1; \
    echo \"# Generated from $pfile\"; \
    for v in PROFILE_NAME PROFILE_DESC TARGET_ARCH TARGET_TRIPLE TOOLCHAIN CROSS_PREFIX SYSROOT CFLAGS CXXFLAGS LDFLAGS MAKEFLAGS PKG_CONFIG_PATH PREFIX; do \
        if [[ -n \${!v:-} ]]; then \
            printf 'export %s=\"%s\"\\n' \"\$v\" \"\${!v}\"; \
        fi; \
    done"
}

# validate minimal fields in a profile (return 0 if ok)
validate_profile_file() {
    local pfile="$1"
    if [[ ! -f "$pfile" ]]; then return 1; fi
    # require PROFILE_NAME and TARGET_ARCH (at least)
    local out
    out=$(bash -c "source \"$pfile\" >/dev/null 2>&1; [[ -n \"\${PROFILE_NAME:-}\" && -n \"\${TARGET_ARCH:-}\" ]] && echo OK || echo FAIL")
    [[ "$out" == "OK" ]]
}

# detect cpu arch and default toolchain; returns detected toolchain name
detect_toolchain() {
    if command -v clang >/dev/null 2>&1; then
        echo "clang"
    elif command -v gcc >/dev/null 2>&1; then
        echo "gcc"
    elif command -v cc >/dev/null 2>&1; then
        echo "cc"
    else
        echo "gcc"
    fi
}

# detect architecture
detect_arch() {
    uname -m
}

# detect nproc
detect_nproc() {
    if command -v nproc >/dev/null 2>&1; then nproc; else echo 1; fi
}

# safe create profile template
create_profile_template() {
    local name="$1"
    local pfile
    pfile="$(profile_path "$name")"
    if [[ -f "$pfile" ]]; then
        echo "Perfil já existe: $name"
        return 1
    fi

    local arch
    arch=$(detect_arch)
    local tool
    tool=$(detect_toolchain)
    local np
    np=$(detect_nproc)

    cat > "$pfile" <<EOF
# ADM Build Profile
# PROFILE_NAME: unique identifier
PROFILE_NAME="${name}"
PROFILE_DESC="Perfil gerado automaticamente: ${name}"

# Target
TARGET_ARCH="${arch}"
TARGET_TRIPLE="${arch}-linux-gnu"

# Toolchain and cross-compilation
TOOLCHAIN="${tool}"
CROSS_PREFIX=""
SYSROOT=""

# Compiler/linker flags
CFLAGS="-O2 -pipe"
CXXFLAGS="\${CFLAGS}"
LDFLAGS="-Wl,-O1,--as-needed"

# Make / build flags
MAKEFLAGS="-j${np}"

# pkg-config and defaults
PKG_CONFIG_PATH="/usr/lib/pkgconfig"
PREFIX="/usr"

# Optional extras:
# ENV_CUSTOM="VAR=VAL another=val"
EOF

    chmod 0644 "$pfile"
    log_change "PROFILE_CREATE: created ${pfile}"
    echo "$pfile"
    return 0
}

# backup current profile (if exists)
backup_current_profile() {
    if [[ -L "${CURRENT_LINK}" ]]; then
        target=$(readlink -f "${CURRENT_LINK}")
        if [[ -f "${target}" ]]; then
            cp -a "${target}" "${BACKUP_FILE}"
            log_change "PROFILE_BACKUP: backed up ${target} -> ${BACKUP_FILE}"
        fi
    elif [[ -f "${CURRENT_LINK}" ]]; then
        # older systems might store file directly
        cp -a "${CURRENT_LINK}" "${BACKUP_FILE}"
        log_change "PROFILE_BACKUP: backed up ${CURRENT_LINK} -> ${BACKUP_FILE}"
    fi
}

# activate profile: create symlink + generate current.env
activate_profile_internal() {
    local name="$1"
    local pfile
    pfile="$(profile_path "$name")"
    if [[ ! -f "$pfile" ]]; then
        echo "Perfil não encontrado: $name"
        return 2
    fi

    # validate profile first
    if ! validate_profile_file "$pfile"; then
        echo "Perfil inválido ou faltando campos obrigatórios: $pfile"
        return 3
    fi

    # pre-profile hook
    if declare -f call_hook >/dev/null 2>&1; then
        call_hook "pre-profile" "$pfile" || true
    fi

    # backup previous
    backup_current_profile

    # create symlink (atomically)
    tmp_link="${CURRENT_LINK}.tmp.$$"
    ln -sf "$pfile" "$tmp_link"
    mv -f "$tmp_link" "${CURRENT_LINK}"

    # write export env file
    dump_profile_exports "$pfile" > "${CURRENT_ENV}"
    chmod 0644 "${CURRENT_ENV}"

    # optionally, update env.sh to source current.env (if not already)
    if [[ -f "${ADM_ROOT}/scripts/env.sh" ]]; then
        if ! grep -q "source ${CURRENT_ENV}" "${ADM_ROOT}/scripts/env.sh" 2>/dev/null; then
            # append a safe source line
            echo "" >> "${ADM_ROOT}/scripts/env.sh"
            echo "# Source active profile env (added by profile.sh)" >> "${ADM_ROOT}/scripts/env.sh"
            echo "if [[ -f \"${CURRENT_ENV}\" ]]; then source \"${CURRENT_ENV}\"; fi" >> "${ADM_ROOT}/scripts/env.sh"
            log_change "PROFILE_ACTIVATE: added source line to env.sh"
        fi
    fi

    # post-profile hook
    if declare -f call_hook >/dev/null 2>&1; then
        call_hook "post-profile" "$pfile" || true
    fi

    log_change "PROFILE_ACTIVATE: ${name}"
    ui_header "Perfil ativado: ${name}"
    echo "Perfil '${name}' ativado. arquivo: ${pfile}"
    echo "Exports gerados em: ${CURRENT_ENV}"
    return 0
}

# delete profile
delete_profile_internal() {
    local name="$1"
    local pfile
    pfile="$(profile_path "$name")"
    if [[ ! -f "$pfile" ]]; then
        echo "Perfil não existe: $name"
        return 1
    fi

    # prevent deleting active profile
    if [[ -L "${CURRENT_LINK}" ]]; then
        cur=$(readlink -f "${CURRENT_LINK}")
        if [[ "$(realpath "$pfile")" == "$(realpath "$cur")" ]]; then
            echo "Não é permitido remover o perfil ativo: $name"
            return 2
        fi
    fi

    rm -f "$pfile"
    log_change "PROFILE_DELETE: ${name}"
    echo "Perfil removido: ${name}"
    return 0
}

# show profile content prettified
show_profile() {
    local name="$1"
    local pfile
    pfile="$(profile_path "$name")"
    if [[ ! -f "$pfile" ]]; then
        echo "Perfil não encontrado: $name"
        return 1
    fi
    ui_header "Perfil: $name"
    sed -n '1,240p' "$pfile" | sed -n '1,200p'
    echo ""
    echo "--- Export preview ---"
    dump_profile_exports "$pfile"
    return 0
}

# edit profile
edit_profile_internal() {
    local name="$1"
    local pfile
    pfile="$(profile_path "$name")"
    if [[ ! -f "$pfile" ]]; then
        echo "Perfil não encontrado: $name"
        return 1
    fi
    ${EDITOR} "$pfile"
    if validate_profile_file "$pfile"; then
        log_change "PROFILE_EDIT: edited ${name}"
        echo "Perfil salvo: $name"
        return 0
    else
        echo "Atenção: perfil pode estar inválido após edição."
        return 2
    fi
}

# list profiles (nice output)
command_list() {
    ui_header "Perfis disponíveis"
    local p
    while IFS= read -r p; do
        pname="${p}"
        if [[ -L "${CURRENT_LINK}" && "$(readlink -f "${CURRENT_LINK}")" == "$(profile_path "$pname")" ]]; then
            printf " * %s (active)\n" "$pname"
        else
            printf "   %s\n" "$pname"
        fi
    done < <(list_profiles_raw)
}

# menu (whiptail/dialog fallback to text)
command_menu() {
    # build options list
    mapfile -t profiles < <(list_profiles_raw)
    if ((${#profiles[@]} == 0)); then
        echo "Nenhum perfil disponível. Crie um com 'profile.sh create <nome>'"
        return 0
    fi

    if command -v whiptail >/dev/null 2>&1 || command -v dialog >/dev/null 2>&1; then
        # use whiptail if available
        local choices=()
        for p in "${profiles[@]}"; do
            choices+=("$p" "" off)
        done
        local sel
        if command -v whiptail >/dev/null 2>&1; then
            sel=$(whiptail --title "ADM Profiles" --menu "Selecione uma ação" 20 78 10 \
                $(for p in "${profiles[@]}"; do echo "$p ''"; done) 3>&1 1>&2 2>&3)
            rc=$?
            if [[ $rc -eq 0 && -n "$sel" ]]; then
                echo "Você escolheu: $sel"
                PS3="Ação para $sel: 1) activate 2) show 3) edit 4) delete 5) cancel > "
                select act in "activate" "show" "edit" "delete" "cancel"; do
                    case "$act" in
                        activate) profile.sh activate "$sel"; break ;;
                        show) profile.sh show "$sel"; break ;;
                        edit) profile.sh edit "$sel"; break ;;
                        delete) profile.sh delete "$sel"; break ;;
                        cancel) break ;;
                    esac
                done
            fi
        else
            echo "dialog disponível mas menu não implementado; continuando para fallback"
        fi
    else
        # text fallback menu
        echo "Profiles menu:"
        PS3="Escolha um perfil (ou 0 para sair): "
        select choice in "${profiles[@]}" "Create new" "Exit"; do
            if [[ "$REPLY" -eq 0 ]] 2>/dev/null; then break; fi
            if [[ -z "$choice" ]]; then echo "Opção inválida"; continue; fi
            if [[ "$choice" == "Create new" ]]; then
                read -r -p "Nome do novo perfil: " newn
                create_profile_template "$newn"
                break
            elif [[ "$choice" == "Exit" ]]; then break
            else
                sel="$choice"
                echo "1) activate  2) show  3) edit  4) delete  5) back"
                read -r -p "Escolha ação: " act
                case "$act" in
                    1) activate_profile_internal "$sel" ;;
                    2) show_profile "$sel" ;;
                    3) edit_profile_internal "$sel" ;;
                    4) read -r -p "Confirmar delete $sel? (y/N): " a; [[ "$a" =~ ^[Yy] ]] && delete_profile_internal "$sel" ;;
                    *) echo "Voltando..." ;;
                esac
                break
            fi
        done
    fi
}

# export current profile to stdout or to file
command_export() {
    local outfile="${1:-}"
    if [[ ! -L "${CURRENT_LINK}" && ! -f "${CURRENT_LINK}" ]]; then
        echo "Nenhum perfil ativo."
        return 1
    fi
    # if env file exists, just cat it
    if [[ -f "${CURRENT_ENV}" ]]; then
        if [[ -n "$outfile" ]]; then
            cp -a "${CURRENT_ENV}" "$outfile"
            echo "Exportado para $outfile"
        else
            cat "${CURRENT_ENV}"
        fi
        return 0
    fi
    # fallback: generate from profile file
    local pfile
    if [[ -L "${CURRENT_LINK}" ]]; then pfile=$(readlink -f "${CURRENT_LINK}"); else pfile="${CURRENT_LINK}"; fi
    if [[ -f "$pfile" ]]; then
        if [[ -n "$outfile" ]]; then
            dump_profile_exports "$pfile" > "$outfile"
            echo "Exportado para $outfile"
        else
            dump_profile_exports "$pfile"
        fi
        return 0
    fi
    return 1
}

# show current profile summary
command_current() {
    if [[ -L "${CURRENT_LINK}" ]]; then
        active=$(basename "$(readlink -f "${CURRENT_LINK}")" .profile)
        ui_header "Perfil ativo"
        echo "Perfil: ${active}"
        echo "Arquivo: $(readlink -f "${CURRENT_LINK}")"
        echo ""
        echo "Preview de variáveis:"
        if [[ -f "${CURRENT_ENV}" ]]; then
            sed -n '1,200p' "${CURRENT_ENV}"
        else
            dump_profile_exports "$(readlink -f "${CURRENT_LINK}")"
        fi
    else
        echo "Nenhum perfil ativo."
    fi
}

# check profile validity command
command_check() {
    require_profile_name "$1"
    local name="$1"
    local pfile
    pfile="$(profile_path "$name")"
    if [[ ! -f "$pfile" ]]; then
        echo "Perfil não encontrado: $name"
        return 2
    fi
    if validate_profile_file "$pfile"; then
        echo "Perfil válido: $name"
        return 0
    else
        echo "Perfil inválido ou faltando campos obrigatórios: $name"
        return 1
    fi
}

# create profile command
command_create() {
    require_profile_name "$1"
    create_profile_template "$1" || return 1
    echo "Perfil criado: $1"
    log_change "PROFILE_CREATE_CMD: $1"
}

# activate command wrapper
command_activate() {
    require_profile_name "$1"
    activate_profile_internal "$1" || return $?
    echo "Ativado: $1"
}

# edit command wrapper
command_edit() {
    require_profile_name "$1"
    edit_profile_internal "$1" || return $?
}

# delete wrapper
command_delete() {
    require_profile_name "$1"
    read -r -p "Confirmar remoção do perfil '$1'? (y/N): " ans
    if [[ "$ans" =~ ^[Yy] ]]; then
        delete_profile_internal "$1"
    else
        echo "Cancelado."
    fi
}

# show wrapper
command_show() {
    require_profile_name "$1"
    show_profile "$1"
}

#-------------------------------------------------------------
# CLI dispatch
#-------------------------------------------------------------
_show_help() {
    cat <<EOF
profile.sh - ADM profile manager

Usage:
  profile.sh list
  profile.sh create <name>
  profile.sh activate <name>
  profile.sh show <name>
  profile.sh current
  profile.sh edit <name>
  profile.sh delete <name>
  profile.sh export [--env-file FILE]
  profile.sh check <name>
  profile.sh menu
  profile.sh --help

Examples:
  profile.sh create x86_64-optim
  profile.sh activate x86_64-optim
  profile.sh current
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if (( $# == 0 )); then
        _show_help
        exit 0
    fi

    cmd="$1"; shift || true
    case "$cmd" in
        list) command_list ;;
        create) command_create "$@" ;;
        activate) command_activate "$@" ;;
        show) command_show "$@" ;;
        current) command_current ;;
        edit) command_edit "$@" ;;
        delete) command_delete "$@" ;;
        export)
            if [[ "$1" == "--env-file" ]]; then
                shift
                command_export "$1"
            else
                command_export ""
            fi
            ;;
        check) command_check "$@" ;;
        menu) command_menu ;;
        --help|-h) _show_help ;;
        *)
            echo "Comando inválido: $cmd"
            _show_help
            exit 2
            ;;
    esac
fi
