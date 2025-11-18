#!/usr/bin/env bash
# 05-install-pkg.sh - Instala pacote binário na árvore final (/usr por padrão),
#                     resolve dependências, executa hooks e registra no DB.
###############################################################################
# Detecção de modo (CLI vs sourced)
###############################################################################

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ADM_INSTALL_CLI_MODE=1
else
    ADM_INSTALL_CLI_MODE=0
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

# Carrega 03-detect/04-build-pkg se existirem (para deps/source)
if [[ -f /usr/src/adm/scripts/03-detect.sh ]]; then
    # shellcheck disable=SC1091
    . /usr/src/adm/scripts/03-detect.sh || true
fi

if [[ -f /usr/src/adm/scripts/04-build-pkg.sh ]]; then
    # shellcheck disable=SC1091
    . /usr/src/adm/scripts/04-build-pkg.sh || true
fi

###############################################################################
# 1. Variáveis internas / helpers básicos
###############################################################################

ADM_INSTALL_ROOT="${ADM_INSTALL_ROOT:-/}"   # raiz final; pode apontar para chroot
ADM_INSTALL_STACK="${ADM_INSTALL_STACK:-}"  # para detectar ciclos de dependência

adm_install_pkg_db_file() {
    local name="$1"
    echo "${ADM_DB_PKG}/${name}.installed"
}

adm_install_is_installed() {
    local name="$1"
    [[ -f "$(adm_install_pkg_db_file "$name")" ]]
}

adm_install_find_metafile_for_pkg() {
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

adm_install_pkgfile_basename() {
    local name="$1" ver="$2"
    echo "${name}-${ver}-${ADM_PROFILE}-${ADM_LIBC}"
}

adm_install_pkgfile_zst() {
    local name="$1" ver="$2"
    echo "${ADM_PKG}/$(adm_install_pkgfile_basename "$name" "$ver").tar.zst"
}

adm_install_pkgfile_xz() {
    local name="$1" ver="$2"
    echo "${ADM_PKG}/$(adm_install_pkgfile_basename "$name" "$ver").tar.xz"
}

adm_install_select_pkgfile() {
    local name="$1" ver="$2"
    local zst xz
    zst="$(adm_install_pkgfile_zst "$name" "$ver")"
    xz="$(adm_install_pkgfile_xz "$name" "$ver")"

    if [[ -f "$zst" ]]; then
        echo "$zst"
    elif [[ -f "$xz" ]]; then
        echo "$xz"
    else
        echo ""
    fi
}

###############################################################################
# 2. Hooks
###############################################################################

adm_install_hooks_base_dir() {
    echo "${ADM_REPO}/${ADM_META_category}/${ADM_META_name}/hook"
}

adm_install_run_hook() {
    local stage="$1"
    local dir hook
    dir="$(adm_install_hooks_base_dir)"
    hook="${dir}/${stage}.sh"

    if [[ -x "$hook" ]]; then
        adm_info "Executando hook '${stage}' em '${hook}'."
        ( cd "${ADM_INSTALL_ROOT}" && "$hook" ) || {
            adm_error "Hook '${stage}' falhou."
            return 1
        }
    fi
}

###############################################################################
# 3. Resolução de dependências (binário + source)
###############################################################################

adm_install_parse_dep_list() {
    local list="$1"
    local -a arr=()
    local IFS=','
    read -r -a arr <<< "$list"
    printf '%s\n' "${arr[@]}"
}

adm_install_has_binary_pkg() {
    local name="$1" ver="$2"
    [[ -n "$(adm_install_select_pkgfile "$name" "$ver")" ]]
}

adm_install_build_from_source() {
    local metafile="$1"

    if [[ ! -x "${ADM_SCRIPTS}/04-build-pkg.sh" ]]; then
        adm_error "04-build-pkg.sh não executável; não posso construir '${metafile}'."
        return 1
    fi

    "${ADM_SCRIPTS}/04-build-pkg.sh" "$metafile"
}

adm_install_ensure_one_dep() {
    local dep="$1"

    [[ -z "$dep" ]] && return 0

    if [[ ",${ADM_INSTALL_STACK}," == *,"${dep}",* ]]; then
        adm_error "Ciclo de dependência detectado em instalação com pacote '${dep}'."
        return 1
    fi

    if adm_install_is_installed "$dep"; then
        adm_debug "Dependência '${dep}' já instalada."
        return 0
    fi

    adm_info "Dependência '${dep}' não instalada; procurando metafile."
    local dep_meta dep_name dep_ver pkgfile
    dep_meta="$(adm_install_find_metafile_for_pkg "$dep" || true)"
    if [[ -z "$dep_meta" ]]; then
        adm_error "Metafile não encontrado para dependência '${dep}'."
        return 1
    fi

    adm_meta_load "$dep_meta" || return 1
    dep_name="${ADM_META_name}"
    dep_ver="${ADM_META_version}"

    pkgfile="$(adm_install_select_pkgfile "$dep_name" "$dep_ver")"

    local old_stack="$ADM_INSTALL_STACK"
    ADM_INSTALL_STACK="${ADM_INSTALL_STACK},${dep_name}"

    if [[ -z "$pkgfile" ]]; then
        adm_info "Nenhum pacote binário encontrado para '${dep_name}-${dep_ver}'; construindo."
        adm_install_build_from_source "$dep_meta" || {
            ADM_INSTALL_STACK="$old_stack"
            return 1
        }
        pkgfile="$(adm_install_select_pkgfile "$dep_name" "$dep_ver")"
        if [[ -z "$pkgfile" ]]; then
            adm_error "Mesmo após construção, pacote de '${dep_name}-${dep_ver}' não foi encontrado."
            ADM_INSTALL_STACK="$old_stack"
            return 1
        fi
    fi

    if [[ ! -x "${ADM_SCRIPTS}/05-install-pkg.sh" ]]; then
        adm_error "05-install-pkg.sh não executável para instalar dependência '${dep_name}'."
        ADM_INSTALL_STACK="$old_stack"
        return 1
    fi

    "${ADM_SCRIPTS}/05-install-pkg.sh" "$dep_name" || {
        ADM_INSTALL_STACK="$old_stack"
        return 1
    }

    ADM_INSTALL_STACK="$old_stack"
    return 0
}

adm_install_ensure_deps_list() {
    local label="$1"
    local list="$2"
    local dep

    adm_info "Resolvendo dependências (${label}): ${list:-<nenhuma>}"

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        adm_install_ensure_one_dep "$dep" || return 1
    done < <(adm_install_parse_dep_list "$list")
}

adm_install_resolve_all_deps() {
    # Em instalação o foco é run_deps; build_deps em geral já foram usados no build,
    # mas podemos garantir que existam também.
    adm_install_ensure_deps_list "run_deps"   "${ADM_META_run_deps}"   || return 1
    adm_install_ensure_deps_list "build_deps" "${ADM_META_build_deps}" || adm_warn "build_deps com falhas; pacote já foi construído, prosseguindo."
    if [[ -n "${ADM_META_opt_deps}" ]]; then
        adm_info "Verificando dependências opcionais: ${ADM_META_opt_deps}"
        adm_install_ensure_deps_list "opt_deps" "${ADM_META_opt_deps}" || adm_warn "Algumas opt_deps não puderam ser instaladas; prosseguindo."
    fi
}

###############################################################################
# 4. Segurança: checagem de permissões
###############################################################################

adm_install_check_permissions() {
    local target_dir="${ADM_INSTALL_ROOT}/usr"
    if [[ ! -d "$target_dir" ]]; then
        mkdir -p "$target_dir" 2>/dev/null || {
            adm_error "Não foi possível criar '$target_dir' (permissões?)."
            return 1
        }
    fi

    if [[ ! -w "$target_dir" ]]; then
        adm_error "Sem permissão de escrita em '$target_dir'. Execute como root (ou ajuste ADM_INSTALL_ROOT/chroot)."
        return 1
    fi
}

###############################################################################
# 5. Extração do pacote e registro de arquivos
###############################################################################

adm_install_extract_and_list_files() {
    local pkgfile="$1"
    local ext
    ext="${pkgfile##*.}"

    mkdir -p "${ADM_INSTALL_ROOT}" || {
        adm_error "Não foi possível criar raiz de instalação '${ADM_INSTALL_ROOT}'."
        return 1
    }

    local filelist
    filelist="$(mktemp "${ADM_ROOT}/.install-files-XXXXXX")" || {
        adm_error "Não foi possível criar arquivo temporário para lista de arquivos."
        return 1
    }

    # Lista e extrai; garantimos que tar leia dentro da raiz virtual
    case "$pkgfile" in
        *.tar.zst)
            if ! command -v zstd >/dev/null 2>&1; then
                adm_error "zstd não disponível para extrair '${pkgfile}'."
                rm -f "$filelist" || true
                return 1
            fi
            tar --use-compress-program zstd -tf "$pkgfile" > "$filelist" 2>/dev/null || {
                adm_error "Falha ao listar conteúdo de '${pkgfile}'."
                rm -f "$filelist" || true
                return 1
            }
            adm_install_run_hook "pre_install"
            tar --use-compress-program zstd -xf "$pkgfile" -C "${ADM_INSTALL_ROOT}" || {
                adm_error "Falha ao extrair '${pkgfile}' em '${ADM_INSTALL_ROOT}'."
                rm -f "$filelist" || true
                return 1
            }
            adm_install_run_hook "post_install"
            ;;
        *.tar.xz)
            tar -tf "$pkgfile" > "$filelist" 2>/dev/null || {
                adm_error "Falha ao listar conteúdo de '${pkgfile}'."
                rm -f "$filelist" || true
                return 1
            }
            adm_install_run_hook "pre_install"
            tar -xJf "$pkgfile" -C "${ADM_INSTALL_ROOT}" || {
                adm_error "Falha ao extrair '${pkgfile}' em '${ADM_INSTALL_ROOT}'."
                rm -f "$filelist" || true
                return 1
            }
            adm_install_run_hook "post_install"
            ;;
        *)
            adm_error "Formato de pacote não suportado: '${pkgfile}'."
            rm -f "$filelist" || true
            return 1
            ;;
    esac

    echo "$filelist"
}

adm_install_register_package() {
    local pkgfile="$1"
    local filelist="$2"

    local name version
    name="${ADM_META_name}"
    version="${ADM_META_version}"

    mkdir -p "${ADM_DB_PKG}" || {
        adm_error "Não foi possível criar DB de pacotes '${ADM_DB_PKG}'."
        return 1
    }

    local dbfile
    dbfile="$(adm_install_pkg_db_file "$name")"

    {
        echo "name=${name}"
        echo "version=${version}"
        echo "category=${ADM_META_category}"
        echo "profile=${ADM_PROFILE}"
        echo "libc=${ADM_LIBC}"
        echo "installed_at=$(date +'%Y-%m-%d %H:%M:%S')"
        echo "install_root=${ADM_INSTALL_ROOT}"
        echo "metafile=${ADM_META_PATH}"
        echo "pkgfile=${pkgfile}"
        echo "run_deps=${ADM_META_run_deps}"
        echo "build_deps=${ADM_META_build_deps}"
        echo "opt_deps=${ADM_META_opt_deps}"
        echo ""
        echo "# Arquivos instalados (relativos à raiz '${ADM_INSTALL_ROOT}')"
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            # Normaliza: sempre com / inicial
            if [[ "$f" != /* ]]; then
                printf '/%s\n' "$f"
            else
                printf '%s\n' "$f"
            fi
        done < "$filelist"
    } > "$dbfile" || {
        adm_error "Falha ao escrever DB de pacote em '${dbfile}'."
        return 1
    }

    adm_info "Pacote registrado em: ${dbfile}"
}

###############################################################################
# 6. Pipeline principal de instalação
###############################################################################

adm_install_pipeline() {
    local metafile="$1"

    adm_init_log "install-$(basename "$metafile")"
    adm_info "Iniciando 05-install-pkg para metafile: ${metafile}"

    adm_meta_load "$metafile" || return 1

    if adm_install_is_installed "${ADM_META_name}"; then
        adm_info "Pacote '${ADM_META_name}' já está instalado; nada a fazer."
        return 0
    fi

    adm_install_check_permissions || return 1

    adm_install_resolve_all_deps || return 1

    local pkgfile
    pkgfile="$(adm_install_select_pkgfile "${ADM_META_name}" "${ADM_META_version}")"

    if [[ -z "$pkgfile" ]]; then
        adm_warn "Nenhum pacote binário encontrado para ${ADM_META_name}-${ADM_META_version}; tentando construir via 04-build-pkg."
        adm_install_build_from_source "$metafile" || return 1
        pkgfile="$(adm_install_select_pkgfile "${ADM_META_name}" "${ADM_META_version}")"
        if [[ -z "$pkgfile" ]]; then
            adm_error "Mesmo após build, pacote binário de '${ADM_META_name}-${ADM_META_version}' não existe."
            return 1
        fi
    fi

    adm_info "Instalando pacote '${ADM_META_name}-${ADM_META_version}' a partir de '${pkgfile}'."

    local filelist
    filelist="$(adm_install_extract_and_list_files "$pkgfile")" || return 1

    adm_install_register_package "$pkgfile" "$filelist" || {
    rm -f "$filelist" || true
    return 1
}

rm -f "$filelist" || true

###############################################################################
# >>> HOOK GLOBAL PÓS-INSTALAÇÃO (adicionar aqui) <<<
###############################################################################
if [[ -f "${ADM_SCRIPTS}/99-global-hooks.sh" ]]; then
    # shellcheck disable=SC1091
    . "${ADM_SCRIPTS}/99-global-hooks.sh"
    if declare -F adm_global_post_install >/dev/null 2>&1; then
        adm_info "Executando hook global pós-instalação para '${ADM_META_name}'."
        adm_global_post_install "${ADM_META_name}" "$(adm_install_pkg_db_file "${ADM_META_name}")" || true
    fi
fi
###############################################################################
# >>> FIM DO HOOK GLOBAL <<< 
###############################################################################

    adm_info "05-install-pkg concluído com sucesso para ${ADM_META_name}-${ADM_META_version}."
}

###############################################################################
# 7. CLI
###############################################################################

adm_install_usage() {
    cat <<EOF
Uso: 05-install-pkg.sh <pacote|caminho_metafile>

- Se for nome de pacote, procura metafile em:
    ${ADM_REPO}/<categoria>/<pacote>/metafile
- Se for caminho de arquivo ou diretório, usa o 'metafile' indicado.

Exemplos:
  05-install-pkg.sh bash
  05-install-pkg.sh ${ADM_REPO}/sys/bash/metafile
EOF
}

adm_install_main() {
    adm_enable_strict_mode

    if [[ $# -lt 1 ]]; then
        adm_install_usage
        exit 1
    fi

    local arg="$1"
    local metafile=""

    if [[ -f "$arg" || -d "$arg" ]]; then
        if [[ -d "$arg" ]]; then
            metafile="${arg%/}/metafile"
        else
            metafile="$arg"
        fi
    else
        metafile="$(adm_install_find_metafile_for_pkg "$arg" || true)"
        if [[ -z "$metafile" ]]; then
            adm_error "Metafile não encontrado para pacote '$arg'."
            exit 1
        fi
    fi

    adm_install_pipeline "$metafile"
}

if [[ "$ADM_INSTALL_CLI_MODE" -eq 1 ]]; then
    adm_install_main "$@"
fi
