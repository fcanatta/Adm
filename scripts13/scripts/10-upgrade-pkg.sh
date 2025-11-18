#!/usr/bin/env bash
# 10-upgrade-pkg.sh
# - Usa metafile em ${ADM_UPDATES}/<programa>/metafile
# - Roda 03-detect.sh -> 04-build-pkg.sh -> 05-install-pkg.sh usando o profile atual
# - Com suporte a upgrade de dependências (via updates/) e verificação de versão instalada
###############################################################################
# Detecção de modo (CLI vs sourced)
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ADM_UPGRADE_CLI_MODE=1
else
    ADM_UPGRADE_CLI_MODE=0
fi

# Carrega env/lib
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

# Carrega detect/build/install se existirem
if [[ -f /usr/src/adm/scripts/03-detect.sh ]]; then
    # shellcheck disable=SC1091
    . /usr/src/adm/scripts/03-detect.sh || true
fi
if [[ -f /usr/src/adm/scripts/04-build-pkg.sh ]]; then
    # shellcheck disable=SC1091
    . /usr/src/adm/scripts/04-build-pkg.sh || true
fi
if [[ -f /usr/src/adm/scripts/05-install-pkg.sh ]]; then
    # shellcheck disable=SC1091
    . /usr/src/adm/scripts/05-install-pkg.sh || true
fi

###############################################################################
# 1. Helpers de paths / DB / versão
###############################################################################

ADM_UPGRADE_STACK="${ADM_UPGRADE_STACK:-}"

adm_upgrade_repo_metafile_for_pkg() {
    local name="$1"
    local f
    if declare -F adm_build_find_metafile_for_pkg >/dev/null 2>&1; then
        adm_build_find_metafile_for_pkg "$name" && return 0
    fi
    if declare -F adm_detect_find_metafile_for_pkg >/dev/null 2>&1; then
        adm_detect_find_metafile_for_pkg "$name" && return 0
    fi
    while IFS= read -r -d '' f; do
        if [[ "$(basename "$(dirname "$f")")" == "$name" ]]; then
            echo "$f"
            return 0
        fi
    done < <(find "${ADM_REPO}" -maxdepth 3 -type f -name "metafile" -print0 2>/dev/null || true)
    return 1
}

adm_upgrade_updates_metafile_for_pkg() {
    local name="$1"
    echo "${ADM_UPDATES}/${name}/metafile"
}

adm_upgrade_pkg_db_file() {
    local name="$1"
    echo "${ADM_DB_PKG}/${name}.installed"
}

adm_upgrade_is_installed() {
    local name="$1"
    [[ -f "$(adm_upgrade_pkg_db_file "$name")" ]]
}

adm_upgrade_installed_version() {
    local name="$1"
    local f line
    f="$(adm_upgrade_pkg_db_file "$name")"
    [[ -f "$f" ]] || { echo ""; return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && break
        if [[ "$line" == version=* ]]; then
            echo "${line#version=}"
            return 0
        fi
    done < "$f"
    echo ""
}

adm_upgrade_is_newer_version() {
    local cur="$1"
    local cand="$2"
    [[ -z "$cand" ]] && return 1
    [[ "$cand" == "$cur" ]] && return 1
    local last
    last="$(printf '%s\n' "$cur" "$cand" | sort -V | tail -n1)"
    [[ "$last" == "$cand" && "$last" != "$cur" ]]
}

###############################################################################
# 2. Detecção de dependências (a partir do metafile de update)
###############################################################################

adm_upgrade_unique_dep_list() {
    local all=""
    [[ -n "${ADM_META_run_deps}"   ]] && all+="${ADM_META_run_deps},"
    [[ -n "${ADM_META_build_deps}" ]] && all+="${ADM_META_build_deps},"
    [[ -n "${ADM_META_opt_deps}"   ]] && all+="${ADM_META_opt_deps},"
    all="${all%,}"
    local -a arr
    local IFS=','
    read -r -a arr <<< "$all"
    declare -A seen=()
    local out=() d
    for d in "${arr[@]}"; do
        [[ -z "$d" ]] && continue
        if [[ -z "${seen[$d]:-}" ]]; then
            seen["$d"]=1
            out+=("$d")
        fi
    done
    printf '%s\n' "${out[@]}"
}

###############################################################################
# 3. Chamadas 03 -> 04 -> 05 para UM metafile
###############################################################################

adm_upgrade_run_detect_build_install() {
    local metafile="$1"

    # 03-detect
    if [[ -x "${ADM_SCRIPTS}/03-detect.sh" ]]; then
        adm_run_with_spinner "Detectando e preparando sources para upgrade (${metafile})..." \
            "${ADM_SCRIPTS}/03-detect.sh" "$metafile" || return 1
    else
        adm_warn "03-detect.sh não executável; 04-build-pkg.sh fará detect interno."
    fi

    # 04-build-pkg
    if [[ -x "${ADM_SCRIPTS}/04-build-pkg.sh" ]]; then
        adm_run_with_spinner "Compilando pacote a partir de '${metafile}'..." \
            "${ADM_SCRIPTS}/04-build-pkg.sh" "$metafile" || return 1
    else
        adm_error "04-build-pkg.sh não executável; não é possível compilar o pacote."
        return 1
    fi

    # 05-install-pkg
    if [[ -x "${ADM_SCRIPTS}/05-install-pkg.sh" ]]; then
        adm_run_with_spinner "Instalando pacote a partir de '${metafile}'..." \
            "${ADM_SCRIPTS}/05-install-pkg.sh" "$metafile" || return 1
    else
        adm_error "05-install-pkg.sh não executável; não é possível instalar o pacote."
        return 1
    fi
}

###############################################################################
# 4. Upgrade de dependência (usando updates/<dep>/metafile se existir)
###############################################################################

adm_upgrade_dep() {
    local dep="$1"
    local with_deps="$2"

    [[ -z "$dep" ]] && return 0

    if [[ ",${ADM_UPGRADE_STACK}," == *,"${dep}",* ]]; then
        adm_error "Ciclo de upgrade detectado com pacote '${dep}'."
        return 1
    fi

    local upd_meta base_meta
    upd_meta="$(adm_upgrade_updates_metafile_for_pkg "$dep")"
    base_meta="$(adm_upgrade_repo_metafile_for_pkg "$dep" 2>/dev/null || true)"

    if [[ ! -f "$upd_meta" ]]; then
        adm_debug "Nenhum metafile de update encontrado para dependência '${dep}' (file: ${upd_meta})."
        # ainda assim garantir que está instalado via 05-install-pkg?
        if [[ -n "$base_meta" ]]; then
            adm_info "Garantindo que dependência '${dep}' esteja instalada."
            if [[ -x "${ADM_SCRIPTS}/05-install-pkg.sh" ]]; then
                "${ADM_SCRIPTS}/05-install-pkg.sh" "$base_meta" || adm_warn "Falha ao instalar dependência '${dep}'."
            else
                adm_warn "05-install-pkg.sh não executável; não consegui instalar '${dep}'."
            fi
        fi
        return 0
    fi

    # Carrega metafile de update da dependência
    adm_meta_load "$upd_meta" || return 1
    local new_ver="${ADM_META_version}"
    local name="${ADM_META_name}"

    local cur_ver
    cur_ver="$(adm_upgrade_installed_version "$name")"

    if [[ -n "$cur_ver" ]] && ! adm_upgrade_is_newer_version "$cur_ver" "$new_ver"; then
        adm_info "Dependência '${name}' já instalada em versão '${cur_ver}' >= '${new_ver}'."
        return 0
    fi

    adm_info "Dependência '${name}' será atualizada de '${cur_ver:-<não_instalado>}' para '${new_ver}'."

    local old_stack="$ADM_UPGRADE_STACK"
    ADM_UPGRADE_STACK="${ADM_UPGRADE_STACK},${name}"

    if [[ "$with_deps" -eq 1 ]]; then
        local d
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            adm_run_with_spinner "Atualizando dependência recursiva '${d}'..." \
                adm_upgrade_dep "$d" "$with_deps" || adm_warn "Falha ao atualizar dependência recursiva '${d}'."
        done < <(adm_upgrade_unique_dep_list)
        # recarrega update metafile da dependência (adm_meta_* pode ter sido alterado pelas recursões)
        adm_meta_load "$upd_meta" || {
            ADM_UPGRADE_STACK="$old_stack"
            return 1
        }
    fi

    adm_upgrade_run_detect_build_install "$upd_meta" || {
        ADM_UPGRADE_STACK="$old_stack"
        return 1
    }

    ADM_UPGRADE_STACK="$old_stack"
    return 0
}

adm_upgrade_all_deps_for_pkg() {
    local with_deps="$1"

    local d
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        adm_run_with_spinner "Atualizando dependência '${d}'..." \
            adm_upgrade_dep "$d" "$with_deps" || adm_warn "Falha ao atualizar dependência '${d}'."
    done < <(adm_upgrade_unique_dep_list)
}

###############################################################################
# 5. Pipeline de upgrade de UM pacote principal
###############################################################################

adm_upgrade_pipeline() {
    local pkg_or_meta="$1"
    local with_deps="$2"

    local upd_meta base_meta
    local pkgname=""
    local from_meta=""

    # Descobre pacote/metafile
    if [[ -f "$pkg_or_meta" || -d "$pkg_or_meta" ]]; then
        if [[ -d "$pkg_or_meta" ]]; then
            from_meta="${pkg_or_meta%/}/metafile"
        else
            from_meta="$pkg_or_meta"
        fi
        adm_meta_load "$from_meta" || return 1
        pkgname="${ADM_META_name}"
    else
        pkgname="$pkg_or_meta"
    fi

    if [[ -z "$pkgname" ]]; then
        adm_error "Não foi possível determinar o nome do pacote a partir de '${pkg_or_meta}'."
        return 1
    fi

    upd_meta="$(adm_upgrade_updates_metafile_for_pkg "$pkgname")"
    base_meta="$(adm_upgrade_repo_metafile_for_pkg "$pkgname" 2>/dev/null || true)"

    if [[ ! -f "$upd_meta" ]]; then
        adm_error "Metafile de update não encontrado para '${pkgname}': ${upd_meta}"
        adm_info  "Sugestão: rode '09-update-pkg.sh ${pkgname}' primeiro."
        return 1
    fi

    adm_meta_load "$upd_meta" || return 1
    local new_ver="${ADM_META_version}"
    local name="${ADM_META_name}"

    local cur_ver=""
    if adm_upgrade_is_installed "$name"; then
        cur_ver="$(adm_upgrade_installed_version "$name")"
    fi

    adm_init_log "upgrade-${name}"
    adm_info "Iniciando upgrade de '${name}'. Versão atual: '${cur_ver:-<não_instalado>}' → nova: '${new_ver}'."

    if [[ -n "$cur_ver" ]] && ! adm_upgrade_is_newer_version "$cur_ver" "$new_ver"; then
        adm_info "Versão instalada '${cur_ver}' já é >= nova '${new_ver}'. Nada a fazer."
        return 0
    fi

    # Upgrade de dependências
    if [[ "$with_deps" -eq 1 ]]; then
        adm_info "Upgrade de dependências habilitado (via updates/)."
        adm_upgrade_all_deps_for_pkg "$with_deps"
        # recarrega metafile do pacote principal (adm_meta_* pode ter sido alterado)
        adm_meta_load "$upd_meta" || return 1
    else
        adm_info "Upgrade de dependências DESABILITADO (--no-deps). Apenas o pacote principal será atualizado."
    fi

    # 03 -> 04 -> 05 para o pacote principal
    adm_upgrade_run_detect_build_install "$upd_meta" || return 1

    adm_info "Upgrade de '${name}' concluído com sucesso."
}

###############################################################################
# 6. CLI
###############################################################################

adm_upgrade_usage() {
    cat <<EOF
Uso: 10-upgrade-pkg.sh [opções] <pacote|caminho_update_metafile>

- Procura o metafile de update em:
    ${ADM_UPDATES}/<programa>/metafile
- Roda na ordem:
    03-detect.sh -> 04-build-pkg.sh -> 05-install-pkg.sh
  usando o profile atual (ADM_PROFILE) e libc atual (ADM_LIBC).

Opções:
  --no-deps   - NÃO atualizar dependências (apenas o pacote principal)
  --deps      - atualizar também as dependências que tiverem metafile em updates/
  -h, --help  - mostrar esta ajuda

Exemplos:
  10-upgrade-pkg.sh bash
  10-upgrade-pkg.sh --deps bash
  10-upgrade-pkg.sh ${ADM_UPDATES}/bash/metafile
EOF
}

adm_upgrade_main() {
    adm_enable_strict_mode

    local with_deps=1
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-deps)
                with_deps=0; shift ;;
            --deps)
                with_deps=1; shift ;;
            -h|--help)
                adm_upgrade_usage
                exit 0
                ;;
            *)
                args+=("$1"); shift ;;
        esac
    done

    if [[ "${#args[@]}" -lt 1 ]]; then
        adm_upgrade_usage
        exit 1
    fi

    local target="${args[0]}"
    adm_upgrade_pipeline "$target" "$with_deps"
}

if [[ "$ADM_UPGRADE_CLI_MODE" -eq 1 ]]; then
    adm_upgrade_main "$@"
fi
