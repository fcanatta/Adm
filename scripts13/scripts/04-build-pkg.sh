#!/usr/bin/env bash
# 04-build-pkg.sh - Compila, testa e empacota um pacote a partir do metafile.
# Pode ser chamado como script (CLI) ou 'sourced' para usar as funções.
###############################################################################
# Detecção de modo (CLI vs sourced)
###############################################################################

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ADM_BUILD_CLI_MODE=1
else
    ADM_BUILD_CLI_MODE=0
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

# Carrega 03-detect.sh para poder usar adm_detect_pipeline e helpers
if [[ -z "${ADM_DETECT_LOADED:-}" ]]; then
    if [[ -f /usr/src/adm/scripts/03-detect.sh ]]; then
        # shellcheck disable=SC1091
        . /usr/src/adm/scripts/03-detect.sh
        ADM_DETECT_LOADED=1
    else
        adm_error "03-detect.sh não encontrado em /usr/src/adm/scripts."
        [[ "$ADM_BUILD_CLI_MODE" -eq 1 ]] && exit 1 || return 1
    fi
fi

###############################################################################
# 1. Variáveis internas
###############################################################################

ADM_BUILD_DESTDIR=""
ADM_BUILD_MANIFEST=""
ADM_BUILD_WORKDIR=""
ADM_BUILD_SYSTEM=""
ADM_BUILD_PKGFILE_ZST=""
ADM_BUILD_PKGFILE_XZ=""

# Stack de build para detectar ciclos de dependência
ADM_BUILD_STACK="${ADM_BUILD_STACK:-}"

###############################################################################
# 2. Helpers de metafile / paths / DB
###############################################################################

adm_build_find_metafile_for_pkg() {
    # Uso: adm_build_find_metafile_for_pkg <nome>
    local name="$1"
    local f

    # Reaproveita busca de 03-detect se existir
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

adm_build_pkg_db_file() {
    local name="$1"
    echo "${ADM_DB_PKG}/${name}.installed"
}

adm_build_is_installed() {
    # Uso: adm_build_is_installed <name>
    local name="$1"
    local f
    f="$(adm_build_pkg_db_file "$name")"
    [[ -f "$f" ]]
}

adm_build_pkgfile_basename() {
    # Uso: adm_build_pkgfile_basename <name> <version>
    local name="$1" ver="$2"
    echo "${name}-${ver}-${ADM_PROFILE}-${ADM_LIBC}"
}

adm_build_pkgfile_zst() {
    local name="$1" ver="$2"
    echo "${ADM_PKG}/$(adm_build_pkgfile_basename "$name" "$ver").tar.zst"
}

adm_build_pkgfile_xz() {
    local name="$1" ver="$2"
    echo "${ADM_PKG}/$(adm_build_pkgfile_basename "$name" "$ver").tar.xz"
}

adm_build_has_binary_pkg() {
    # Uso: adm_build_has_binary_pkg <name> <version>
    local name="$1" ver="$2"
    local zst xz
    zst="$(adm_build_pkgfile_zst "$name" "$ver")"
    xz="$(adm_build_pkgfile_xz "$name" "$ver")"
    [[ -f "$zst" || -f "$xz" ]]
}

###############################################################################
# 3. Hooks
###############################################################################

adm_build_hooks_base_dir() {
    echo "${ADM_REPO}/${ADM_META_category}/${ADM_META_name}/hook"
}

adm_build_run_hook() {
    # Uso: adm_build_run_hook <stage>
    local stage="$1"
    local dir hook
    dir="$(adm_build_hooks_base_dir)"
    hook="${dir}/${stage}.sh"

    if [[ -x "$hook" ]]; then
        adm_info "Executando hook '${stage}' em '${hook}'."
        ( cd "${ADM_BUILD_WORKDIR:-.}" && "$hook" ) || {
            adm_error "Hook '${stage}' falhou."
            return 1
        }
    fi
}

###############################################################################
# 4. Carregar manifesto de source (.adm-source-manifest)
###############################################################################

adm_build_load_source_manifest() {
    local name version
    name="${ADM_META_name}"
    version="${ADM_META_version}"

    local buildroot="${ADM_BUILD}/${name}-${version}"
    local manifest="${buildroot}/.adm-source-manifest"

    if [[ ! -f "$manifest" ]]; then
        adm_info "Manifesto de source não encontrado; rodando 03-detect para '${name}-${version}'."
        adm_detect_pipeline "$(adm_meta_get path)" || {
            adm_error "03-detect falhou para '${name}-${version}'."
            return 1
        }
    fi

    if [[ ! -f "$manifest" ]]; then
        adm_error "Manifesto de source ainda ausente após detect: '${manifest}'."
        return 1
    fi

    ADM_BUILD_MANIFEST="$manifest"

    # shellcheck disable=SC1090
    . "$manifest"

    # As variáveis carregadas: build_root, workdir, build_system
    ADM_BUILD_WORKDIR="${workdir:-${build_root:-${ADM_BUILD}/${name}-${version}}}"
    ADM_BUILD_SYSTEM="${build_system:-custom}"
}

###############################################################################
# 5. Resolução de dependências (run/build/opt)
###############################################################################

adm_build_parse_dep_list() {
    local list="$1"
    local -a arr=()
    local IFS=','
    read -r -a arr <<< "$list"
    printf '%s\n' "${arr[@]}"
}

adm_build_ensure_one_dep() {
    local dep="$1"

    [[ -z "$dep" ]] && return 0

    # Evita ciclo simples
    if [[ ",${ADM_BUILD_STACK}," == *,"${dep}",* ]]; then
        adm_error "Ciclo de dependência detectado com pacote '${dep}'."
        return 1
    fi

    if adm_build_is_installed "$dep"; then
        adm_debug "Dependência '${dep}' já instalada."
        return 0
    fi

    adm_info "Dependência '${dep}' não instalada; verificando pacote binário."

    # Descobrir metafile do dep
    local dep_meta dep_name dep_ver
    dep_meta="$(adm_build_find_metafile_for_pkg "$dep" || true)"
    if [[ -z "$dep_meta" ]]; then
        adm_error "Metafile não encontrado para dependência '${dep}'."
        return 1
    fi

    adm_meta_load "$dep_meta" || return 1
    dep_name="${ADM_META_name}"
    dep_ver="${ADM_META_version}"

    if adm_build_has_binary_pkg "$dep_name" "$dep_ver"; then
        adm_info "Pacote binário já existente para '${dep_name}-${dep_ver}', chamando 05-install-pkg.sh."
        if [[ -x "${ADM_SCRIPTS}/05-install-pkg.sh" ]]; then
            "${ADM_SCRIPTS}/05-install-pkg.sh" "$dep_name" || return 1
        else
            adm_error "05-install-pkg.sh não encontrado ou não executável; não consigo instalar dependência '${dep_name}'."
            return 1
        fi
        return 0
    fi

    adm_info "Construindo e instalando dependência '${dep_name}-${dep_ver}'."

    # Evita ciclos mais complexos: adiciona ao stack e chama recursivamente
    local old_stack="$ADM_BUILD_STACK"
    ADM_BUILD_STACK="${ADM_BUILD_STACK},${dep_name}"

    if [[ -x "${ADM_SCRIPTS}/04-build-pkg.sh" ]]; then
        "${ADM_SCRIPTS}/04-build-pkg.sh" "$dep_meta" || {
            ADM_BUILD_STACK="$old_stack"
            return 1
        }
    else
        adm_error "04-build-pkg.sh não executável para construir dependência '${dep_name}'."
        ADM_BUILD_STACK="$old_stack"
        return 1
    fi

    # Agora instala
    if [[ -x "${ADM_SCRIPTS}/05-install-pkg.sh" ]]; then
        "${ADM_SCRIPTS}/05-install-pkg.sh" "$dep_name" || {
            ADM_BUILD_STACK="$old_stack"
            return 1
        }
    else
        adm_error "05-install-pkg.sh não executável para instalar dependência '${dep_name}'."
        ADM_BUILD_STACK="$old_stack"
        return 1
    fi

    ADM_BUILD_STACK="$old_stack"
    return 0
}

adm_build_ensure_deps_list() {
    local label="$1"
    local list="$2"
    local dep

    adm_info "Resolvendo dependências (${label}): ${list:-<nenhuma>}"

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        adm_build_ensure_one_dep "$dep" || return 1
    done < <(adm_build_parse_dep_list "$list")
}

adm_build_resolve_all_deps() {
    adm_build_ensure_deps_list "build_deps" "${ADM_META_build_deps}" || return 1
    adm_build_ensure_deps_list "run_deps"   "${ADM_META_run_deps}"   || return 1

    # opt_deps tratados como opcionais, mas se já estiverem instalados ou puderem ser instalados,
    # melhor garantir
    if [[ -n "${ADM_META_opt_deps}" ]]; then
        adm_info "Verificando dependências opcionais: ${ADM_META_opt_deps}"
        adm_build_ensure_deps_list "opt_deps" "${ADM_META_opt_deps}" || adm_warn "Algumas opt_deps falharam; prosseguindo mesmo assim."
    fi
}

###############################################################################
# 6. Preparação de DESTDIR e ambiente de build
###############################################################################

adm_build_prepare_destdir() {
    ADM_BUILD_DESTDIR="${ADM_BUILD}/${ADM_META_name}-${ADM_META_version}/destdir"
    if [[ -d "$ADM_BUILD_DESTDIR" ]]; then
        adm_warn "DESTDIR '${ADM_BUILD_DESTDIR}' já existe; será limpo."
        rm -rf "${ADM_BUILD_DESTDIR}"/* 2>/dev/null || true
    else
        mkdir -p "$ADM_BUILD_DESTDIR" || {
            adm_error "Não foi possível criar DESTDIR '${ADM_BUILD_DESTDIR}'."
            return 1
        }
    fi
}

adm_build_enter_workdir() {
    if [[ -z "${ADM_BUILD_WORKDIR:-}" || ! -d "${ADM_BUILD_WORKDIR}" ]]; then
        adm_error "Diretório de trabalho inválido: '${ADM_BUILD_WORKDIR:-<vazio>}'"
        return 1
    fi
    cd "${ADM_BUILD_WORKDIR}" || {
        adm_error "Falha ao entrar no diretório de trabalho '${ADM_BUILD_WORKDIR}'."
        return 1
    }
}

###############################################################################
# 7. Funções por sistema de build
###############################################################################

adm_build_run_autotools() {
    adm_build_run_hook "pre_configure"

    ./configure \
        --prefix=/usr \
        --disable-static \
        --build="$(uname -m)-unknown-linux-gnu" \
        --host="${ADM_TARGET}" \
        CPPFLAGS="${CPPFLAGS}" \
        CFLAGS="${CFLAGS}" \
        CXXFLAGS="${CXXFLAGS}" \
        LDFLAGS="${LDFLAGS}" || return 1

    adm_build_run_hook "post_configure"

    adm_build_run_hook "pre_build"
    make ${MAKEFLAGS:-} || return 1
    adm_build_run_hook "post_build"

    if [[ "${ADM_SKIP_TESTS:-0}" -ne 1 ]]; then
        adm_build_run_hook "pre_test"
        if make check ${MAKEFLAGS:-}; then
            :
        else
            adm_warn "Testes (make check) falharam, verifique logs."
        fi
        adm_build_run_hook "post_test"
    fi

    adm_build_run_hook "pre_install"
    make DESTDIR="${ADM_BUILD_DESTDIR}" install || return 1
    adm_build_run_hook "post_install"
}

adm_build_run_cmake() {
    adm_build_run_hook "pre_configure"
    mkdir -p build && cd build || return 1

    cmake .. \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
        -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
        -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}" || return 1

    adm_build_run_hook "post_configure"

    adm_build_run_hook "pre_build"
    cmake --build . -- -j"${ADM_JOBS}" || return 1
    adm_build_run_hook "post_build"

    if [[ "${ADM_SKIP_TESTS:-0}" -ne 1 ]]; then
        adm_build_run_hook "pre_test"
        if ctest --output-on-failure; then
            :
        else
            adm_warn "ctest reportou falhas; verifique logs."
        fi
        adm_build_run_hook "post_test"
    fi

    adm_build_run_hook "pre_install"
    cmake --install . --prefix /usr --config Release -- DESTDIR="${ADM_BUILD_DESTDIR}" || return 1
    adm_build_run_hook "post_install"
}

adm_build_run_meson() {
    adm_build_run_hook "pre_configure"
    local bdir="build"
    meson setup "$bdir" . \
        --prefix=/usr \
        --buildtype=release \
        -Ddefault_library=shared || return 1
    adm_build_run_hook "post_configure"

    adm_build_run_hook "pre_build"
    meson compile -C "$bdir" || return 1
    adm_build_run_hook "post_build"

    if [[ "${ADM_SKIP_TESTS:-0}" -ne 1 ]]; then
        adm_build_run_hook "pre_test"
        if meson test -C "$bdir" --print-errorlogs; then
            :
        else
            adm_warn "meson test reportou falhas; verifique logs."
        fi
        adm_build_run_hook "post_test"
    fi

    adm_build_run_hook "pre_install"
    meson install -C "$bdir" --destdir "${ADM_BUILD_DESTDIR}" || return 1
    adm_build_run_hook "post_install"
}

adm_build_run_make() {
    adm_build_run_hook "pre_configure"
    # muitos projetos make-only não precisam de configure
    adm_build_run_hook "post_configure"

    adm_build_run_hook "pre_build"
    make ${MAKEFLAGS:-} || return 1
    adm_build_run_hook "post_build"

    if [[ "${ADM_SKIP_TESTS:-0}" -ne 1 ]]; then
        adm_build_run_hook "pre_test"
        if make test ${MAKEFLAGS:-} 2>/dev/null || make check ${MAKEFLAGS:-} 2>/dev/null; then
            :
        else
            adm_warn "Testes via make falharam ou não existem."
        fi
        adm_build_run_hook "post_test"
    fi

    adm_build_run_hook "pre_install"
    make DESTDIR="${ADM_BUILD_DESTDIR}" install || return 1
    adm_build_run_hook "post_install"
}
adm_build_run_cargo() {
    adm_build_run_hook "pre_build"
    if ! command -v cargo >/dev/null 2>&1; then
        adm_error "cargo não encontrado para build_type=cargo."
        return 1
    fi

    cargo build --release || return 1
    adm_build_run_hook "post_build"

    if [[ "${ADM_SKIP_TESTS:-0}" -ne 1 ]]; then
        adm_build_run_hook "pre_test"
        if cargo test --release; then
            :
        else
            adm_warn "cargo test reportou falhas."
        fi
        adm_build_run_hook "post_test"
    fi

    adm_build_run_hook "pre_install"
    # instalação genérica em /usr/bin
    mkdir -p "${ADM_BUILD_DESTDIR}/usr/bin" || return 1
    find target/release -maxdepth 1 -type f -perm -111 -exec cp {} "${ADM_BUILD_DESTDIR}/usr/bin/" \; 2>/dev/null || true
    adm_build_run_hook "post_install"
}

adm_build_run_python() {
    adm_build_run_hook "pre_build"
    if ! command -v python3 >/dev/null 2>&1; then
        adm_error "python3 não encontrado para build_type=python."
        return 1
    fi

    if [[ -f "pyproject.toml" ]]; then
        python3 -m pip wheel . -w dist || adm_warn "Falha ao gerar wheel; tentando setup.py se existir."
    fi

    if [[ -f "setup.py" ]]; then
        python3 setup.py build || return 1
        if [[ "${ADM_SKIP_TESTS:-0}" -ne 1 ]] && command -v pytest >/dev/null 2>&1; then
            adm_build_run_hook "pre_test"
            if pytest; then
                :
            else
                adm_warn "pytest reportou falhas."
            fi
            adm_build_run_hook "post_test"
        fi
        adm_build_run_hook "pre_install"
        python3 setup.py install --root="${ADM_BUILD_DESTDIR}" --prefix=/usr || return 1
        adm_build_run_hook "post_install"
    else
        adm_warn "Nenhum setup.py encontrado; instalando via pip para DESTDIR (experimental)."
        adm_build_run_hook "pre_install"
        python3 -m pip install . --root "${ADM_BUILD_DESTDIR}" --prefix /usr || return 1
        adm_build_run_hook "post_install"
    fi
}

adm_build_run_node() {
    adm_build_run_hook "pre_build"
    if ! command -v npm >/dev/null 2>&1; then
        adm_error "npm não encontrado para build_type=node."
        return 1
    fi

    npm install || return 1
    if npm run build 2>/dev/null; then
        :
    else
        adm_warn "npm run build falhou ou não existe; prosseguindo."
    fi
    adm_build_run_hook "post_build"

    if [[ "${ADM_SKIP_TESTS:-0}" -ne 1 ]]; then
        adm_build_run_hook "pre_test"
        if npm test 2>/dev/null; then
            :
        else
            adm_warn "npm test falhou ou não existe."
        fi
        adm_build_run_hook "post_test"
    fi

    adm_build_run_hook "pre_install"
    mkdir -p "${ADM_BUILD_DESTDIR}/usr/lib/${ADM_META_name}" || return 1
    cp -a . "${ADM_BUILD_DESTDIR}/usr/lib/${ADM_META_name}/" || true
    adm_build_run_hook "post_install"
}

adm_build_run_custom() {
    # Para build_type=custom, assume que hooks fazem tudo
    adm_info "build_type=custom: esperando que hooks cuidem do build/test/install."
    adm_build_run_hook "pre_configure"
    adm_build_run_hook "post_configure"
    adm_build_run_hook "pre_build"
    adm_build_run_hook "post_build"
    if [[ "${ADM_SKIP_TESTS:-0}" -ne 1 ]]; then
        adm_build_run_hook "pre_test"
        adm_build_run_hook "post_test"
    fi
    adm_build_run_hook "pre_install"
    adm_build_run_hook "post_install"
}

adm_build_run_for_system() {
    case "$ADM_BUILD_SYSTEM" in
        autotools) adm_build_run_autotools ;;
        cmake)     adm_build_run_cmake    ;;
        meson)     adm_build_run_meson    ;;
        make)      adm_build_run_make     ;;
        cargo)     adm_build_run_cargo    ;;
        python)    adm_build_run_python   ;;
        node)      adm_build_run_node     ;;
        custom|*)  adm_build_run_custom   ;;
    esac
}

###############################################################################
# 8. Empacotamento e registro de build
###############################################################################

adm_build_package() {
    local name version
    name="${ADM_META_name}"
    version="${ADM_META_version}"

    if [[ ! -d "${ADM_BUILD_DESTDIR}" ]]; then
        adm_error "DESTDIR '${ADM_BUILD_DESTDIR}' inexistente para empacotar."
        return 1
    fi

    local base
    base="$(adm_build_pkgfile_basename "$name" "$version")"

    ADM_BUILD_PKGFILE_ZST="${ADM_PKG}/${base}.tar.zst"
    ADM_BUILD_PKGFILE_XZ="${ADM_PKG}/${base}.tar.xz"

    mkdir -p "${ADM_PKG}" || {
        adm_error "Não foi possível criar diretório de pacotes '${ADM_PKG}'."
        return 1
    }

    ( cd "${ADM_BUILD_DESTDIR}" && tar -cf - . ) | xz -T"${ADM_JOBS}" -c > "${ADM_BUILD_PKGFILE_XZ}" || {
        adm_error "Falha ao criar pacote XZ: '${ADM_BUILD_PKGFILE_XZ}'."
        return 1
    }

    if command -v zstd >/dev/null 2>&1; then
        ( cd "${ADM_BUILD_DESTDIR}" && tar -cf - . ) | zstd -T"${ADM_JOBS}" -q -o "${ADM_BUILD_PKGFILE_ZST}" || {
            adm_error "Falha ao criar pacote ZST: '${ADM_BUILD_PKGFILE_ZST}'."
            return 1
        }
    else
        adm_warn "zstd não disponível; pacote .tar.zst não será criado."
        ADM_BUILD_PKGFILE_ZST=""
    fi

    adm_info "Pacotes criados:"
    adm_info "  XZ : ${ADM_BUILD_PKGFILE_XZ}"
    [[ -n "${ADM_BUILD_PKGFILE_ZST}" ]] && adm_info "  ZST: ${ADM_BUILD_PKGFILE_ZST}"

    adm_build_register_build
}

adm_build_register_build() {
    local name version f
    name="${ADM_META_name}"
    version="${ADM_META_version}"

    mkdir -p "${ADM_DB_BUILD}" || {
        adm_error "Não foi possível criar diretório de DB de builds '${ADM_DB_BUILD}'."
        return 1
    }

    adm_meta_increment_builds

    f="${ADM_DB_BUILD}/${name}-${version}.build"

    {
        echo "name=${name}"
        echo "version=${version}"
        echo "category=${ADM_META_category}"
        echo "profile=${ADM_PROFILE}"
        echo "libc=${ADM_LIBC}"
        echo "num_builds=${ADM_META_num_builds}"
        echo "built_at=$(date +'%Y-%m-%d %H:%M:%S')"
        echo "pkgfile_xz=${ADM_BUILD_PKGFILE_XZ}"
        echo "pkgfile_zst=${ADM_BUILD_PKGFILE_ZST}"
    } > "$f" || {
        adm_error "Falha ao escrever registro de build em '${f}'."
        return 1
    }

    adm_info "Build registrado em: ${f}"
}

###############################################################################
# 9. Pipeline principal de build
###############################################################################

adm_build_pipeline() {
    local metafile="$1"

    adm_init_log "build-$(basename "$metafile")"
    adm_info "Iniciando 04-build-pkg para metafile: ${metafile}"

    adm_meta_load "$metafile" || return 1

    # Evita loop sobre o próprio pacote
    if [[ ",${ADM_BUILD_STACK}," == *,"${ADM_META_name}",* ]]; then
        adm_error "Ciclo de build detectado com o próprio pacote '${ADM_META_name}'."
        return 1
    fi
    ADM_BUILD_STACK="${ADM_BUILD_STACK},${ADM_META_name}"

    adm_build_resolve_all_deps || return 1

    adm_run_with_spinner "Carregando manifesto de source..." adm_build_load_source_manifest || return 1
    adm_run_with_spinner "Preparando DESTDIR..." adm_build_prepare_destdir || return 1

    adm_build_enter_workdir || return 1

    adm_build_run_hook "pre_detect"
    adm_build_run_hook "post_detect"

    adm_info "Compilando '${ADM_META_name}-${ADM_META_version}' com build_system=${ADM_BUILD_SYSTEM}."
    adm_build_run_for_system || return 1

    adm_build_run_hook "pre_pkg"
    adm_build_package || return 1
    adm_build_run_hook "post_pkg"

    adm_info "04-build-pkg concluído com sucesso para ${ADM_META_name}-${ADM_META_version}."
}

###############################################################################
# 10. CLI
###############################################################################

adm_build_usage() {
    cat <<EOF
Uso: 04-build-pkg.sh <pacote|caminho_metafile>

- Se for nome de pacote, procura metafile em:
    ${ADM_REPO}/<categoria>/<pacote>/metafile
- Se for caminho de arquivo ou diretório, usa o 'metafile' indicado.

Exemplos:
  04-build-pkg.sh bash
  04-build-pkg.sh ${ADM_REPO}/sys/bash/metafile
EOF
}

adm_build_main() {
    adm_enable_strict_mode

    if [[ $# -lt 1 ]]; then
        adm_build_usage
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
        metafile="$(adm_build_find_metafile_for_pkg "$arg" || true)"
        if [[ -z "$metafile" ]]; then
            adm_error "Metafile não encontrado para pacote '$arg'."
            exit 1
        fi
    fi

    adm_build_pipeline "$metafile"
}

if [[ "$ADM_BUILD_CLI_MODE" -eq 1 ]]; then
    adm_build_main "$@"
fi
