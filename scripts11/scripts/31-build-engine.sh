#!/usr/bin/env bash
# 31-build-engine.sh
# Motor de construção inteligente do ADM.
#
# Objetivo:
#   - Construir praticamente qualquer programa baseado em:
#       * metafile (10-repo-metafile.sh)
#       * source manager (30-source-manager.sh)
#       * resolver de deps (32-resolver-deps.sh)
#       * hooks + patches (12-hooks-patches.sh, mas usados só quando necessário)
#       * cache binário (13-binary-cache.sh)
#   - Minimizar uso de hooks: só quando o build system padrão não dá conta.
#
# Interfaces principais (funções públicas):
#
#   adm_build_pkg <categoria> <nome> <modo> <destdir>
#       - Constrói o pacote e suas dependências.
#       - modo: "build", "run", "all", "stage1", "stage2", "native" (todos tratam como "build/all", mas
#         podem influenciar flags/cross no futuro).
#
#   adm_build_pkg_from_token <token> <modo> <destdir>
#       - token: "cat/pkg" ou apenas "pkg"
#
#   (Compat) adm_build_engine_build <categoria> <nome> <modo> <destdir>
#       - alias para adm_build_pkg (usado por scripts antigos).
#
# Quando executado diretamente:
#   31-build-engine.sh build-token <token> [modo] [destdir]
#   31-build-engine.sh build       <categoria> <nome> [modo] [destdir]

# ----------------------------------------------------------------------
# Requisitos e modo seguro
# ----------------------------------------------------------------------

if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 31-build-engine.sh requer bash." >&2
    exit 1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERRO: 31-build-engine.sh requer bash >= 4." >&2
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------
# Ambiente básico e logging
# ----------------------------------------------------------------------

ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"
ADM_SCRIPTS="${ADM_SCRIPTS:-$ADM_ROOT/scripts}"
ADM_REPO="${ADM_REPO:-$ADM_ROOT/repo}"
ADM_WORK="${ADM_WORK:-$ADM_ROOT/work}"

# Vars típicas de profile/toolchain (vêm de 00-env-profiles.sh, se disponível)
ADM_PROFILE="${ADM_PROFILE:-normal}"
ADM_TARGET="${ADM_TARGET:-}"
ADM_HOST="${ADM_HOST:-}"
ADM_BUILD="${ADM_BUILD:-}"
ADM_LIBC="${ADM_LIBC:-glibc}"

# Logging UI (01-log-ui.sh) ou fallback simples
if ! declare -F adm_info >/dev/null 2>&1; then
    adm_log_ts() { date +"%Y-%m-%d %H:%M:%S"; }
    adm_info()   { printf '[%s] [INFO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_warn()   { printf '[%s] [WARN] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_error()  { printf '[%s] [ERRO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_die()    { adm_error "$*"; exit 1; }
fi

if ! declare -F adm_stage >/dev/null 2>&1; then
    adm_stage() { adm_info "===== STAGE: $* ====="; }
fi

if ! declare -F adm_ensure_dir >/dev/null 2>&1; then
    adm_ensure_dir() {
        local d="${1:-}"
        if [ -z "$d" ]; then
            adm_die "adm_ensure_dir chamado com caminho vazio"
        fi
        if [ -d "$d" ]; then
            return 0
        fi
        if ! mkdir -p "$d"; then
            adm_die "Falha ao criar diretório: $d"
        fi
    }
fi

if ! declare -F adm_run_with_spinner >/dev/null 2>&1; then
    adm_run_with_spinner() {
        # fallback sem spinner
        local msg="$1"; shift
        adm_info "$msg"
        "$@"
    }
fi

# Sanitizadores (caso 10-repo-metafile não esteja carregado)
if ! declare -F adm_repo_sanitize_name >/dev/null 2>&1; then
    adm_repo_sanitize_name() {
        local n="${1:-}"
        if [ -z "$n" ]; then
            adm_die "Nome vazio não é permitido"
        fi
        if [[ ! "$n" =~ ^[A-Za-z0-9._+-]+$ ]]; then
            adm_die "Nome inválido '$n'. Use apenas [A-Za-z0-9._+-]."
        fi
        printf '%s' "$n"
    }
fi

if ! declare -F adm_repo_sanitize_category >/dev/null 2>&1; then
    adm_repo_sanitize_category() {
        local c="${1:-}"
        if [ -z "$c" ]; then
            adm_die "Categoria vazia não é permitida"
        fi
        if [[ ! "$c" =~ ^[A-Za-z0-9._+-]+$ ]]; then
            adm_die "Categoria inválida '$c'. Use apenas [A-Za-z0-9._+-]."
        fi
        printf '%s' "$c"
    }
fi

# Hooks/patches (12-hooks-patches.sh) – se não carregado, criamos stubs seguros.
if ! declare -F adm_hooks_run_stage >/dev/null 2>&1; then
    adm_hooks_run_stage() {
        # category name stage [workdir] [destdir]
        local c="${1:-}" n="${2:-}" st="${3:-}"
        adm_info "Hooks não carregados; ignorando stage '$st' para $c/$n."
        return 0
    }
fi

if ! declare -F adm_hooks_and_patches_for_stage >/dev/null 2>&1; then
    adm_hooks_and_patches_for_stage() {
        # category name stage [workdir] [destdir]
        local c="${1:-}" n="${2:-}" st="${3:-}"
        adm_info "Hooks/Patches não carregados; ignorando stage '$st' para $c/$n (sem patches automáticos)."
        return 0
    }
fi

# Binary cache (13-binary-cache.sh) – se não existir, tratamos como desativado
ADM_BUILD_CACHE_ENABLED=0
if declare -F adm_cache_exists >/dev/null 2>&1 && \
   declare -F adm_cache_validate >/dev/null 2>&1 && \
   declare -F adm_cache_extract_to_destdir >/dev/null 2>&1 && \
   declare -F adm_cache_store_from_destdir >/dev/null 2>&1; then
    ADM_BUILD_CACHE_ENABLED=1
fi

# Resolver de deps (32-resolver-deps.sh) – se não existir, construímos só o alvo principal.
ADM_BUILD_DEPS_ENABLED=0
if declare -F adm_deps_resolve_for_pkg >/dev/null 2>&1 && \
   declare -F adm_deps_resolve_from_token >/dev/null 2>&1; then
    ADM_BUILD_DEPS_ENABLED=1
fi

# Source manager (30-source-manager.sh) – obrigatório para construir
if ! declare -F adm_src_fetch_for_pkg >/dev/null 2>&1; then
    adm_die "adm_src_fetch_for_pkg não disponível. Carregue 30-source-manager.sh antes de usar o build-engine."
fi

if ! declare -F adm_meta_load >/dev/null 2>&1 || \
   ! declare -F adm_meta_get_var >/dev/null 2>&1; then
    adm_die "Funções de metafile (adm_meta_load/adm_meta_get_var) não disponíveis. Carregue 10-repo-metafile.sh."
fi

# ----------------------------------------------------------------------
# Estado interno do build
# ----------------------------------------------------------------------

# Pacotes já construídos (para evitar recursão infinita / rebuilds)
declare -Ag ADM_BUILD_DONE

adm_build_key() {
    local c="${1:-}" n="${2:-}"
    printf '%s/%s' "$c" "$n"
}

# ----------------------------------------------------------------------
# Parsing de token de pacote: "cat/pkg" ou "pkg"
# ----------------------------------------------------------------------

adm_build_parse_token() {
    local token_raw="${1:-}"
    local token
    token="${token_raw#"${token_raw%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"

    if [ -z "$token" ]; then
        adm_die "adm_build_parse_token chamado com token vazio."
    fi

    if [[ "$token" == */* ]]; then
        local category_part="${token%%/*}"
        local name_part="${token#*/}"
        local c n
        c="$(adm_repo_sanitize_category "$category_part")"
        n="$(adm_repo_sanitize_name "$name_part")"
        printf '%s %s\n' "$c" "$n"
    else
        # Usar resolver para descobrir categoria
        if declare -F adm_deps_parse_token >/dev/null 2>&1; then
            # 32-resolver-deps.sh expõe adm_deps_parse_token
            local out
            out="$(adm_deps_parse_token "$token")"
            printf '%s\n' "$out"
        elif declare -F adm_deps_find_by_name >/dev/null 2>&1; then
            local out
            out="$(adm_deps_find_by_name "$token")"
            printf '%s\n' "$out"
        else
            # fallback: busca manual no repo
            local name
            name="$(adm_repo_sanitize_name "$token")"
            local matches=() cat_dir pkg_dir cat pkg
            if [ ! -d "$ADM_REPO" ]; then
                adm_die "ADM_REPO não existe: $ADM_REPO (não é possível resolver '$token')."
            fi
            for cat_dir in "$ADM_REPO"/*; do
                [ -d "$cat_dir" ] || continue
                cat="$(basename "$cat_dir")"
                for pkg_dir in "$cat_dir"/*; do
                    [ -d "$pkg_dir" ] || continue
                    pkg="$(basename "$pkg_dir")"
                    if [ "$pkg" = "$name" ] && [ -f "$pkg_dir/metafile" ]; then
                        matches+=("$cat $pkg")
                    fi
                done
            done
            local count="${#matches[@]}"
            if [ "$count" -eq 0 ]; then
                adm_die "Pacote '$name' não encontrado em nenhuma categoria do repo."
            elif [ "$count" -gt 1 ]; then
                adm_error "Pacote '$name' é ambíguo; múltiplas categorias:"
                local m
                for m in "${matches[@]}"; do
                    adm_error "  - $m"
                done
                adm_die "Use 'categoria/nome' para esse pacote."
            fi
            printf '%s\n' "${matches[0]}"
        fi
    fi
}

# ----------------------------------------------------------------------
# Ambiente de build / destdir
# ----------------------------------------------------------------------

adm_build_normalize_mode() {
    local mode="${1:-build}"
    case "$mode" in
        build|run|all|stage1|stage2|native)
            printf '%s\n' "$mode"
            ;;
        *)
            adm_warn "Modo de build desconhecido '$mode'; usando 'build'."
            printf '%s\n' "build"
            ;;
    esac
}

adm_build_effective_dep_mode() {
    # Como vamos resolver deps para cada modo de build.
    local mode="${1:-build}"
    case "$mode" in
        build|stage1|stage2|native)
            printf '%s\n' "build"
            ;;
        run)
            printf '%s\n' "run"
            ;;
        all)
            printf '%s\n' "all"
            ;;
        *)
            printf '%s\n' "build"
            ;;
    esac
}

adm_build_init_paths() {
    adm_ensure_dir "$ADM_WORK"
}

adm_build_prepare_destdir() {
    local destdir="${1:-}"

    if [ -z "$destdir" ]; then
        destdir="/"
    fi

    # Normalizar // -> /
    destdir="$(printf '%s' "$destdir" | sed 's://*:/:g')"

    if [ "$destdir" != "/" ]; then
        adm_ensure_dir "$destdir"
    fi

    printf '%s\n' "$destdir"
}

# ----------------------------------------------------------------------
# Helpers de build system: seleção de estratégia
# ----------------------------------------------------------------------

adm_build_choose_strategy() {
    # Usa ADM_SRC_DETECTED_* para escolher estratégia de build.
    # workdir já preparado por adm_src_fetch_for_pkg.
    local workdir="${1:-}"

    [ -z "$workdir" ] && adm_die "adm_build_choose_strategy requer workdir"

    local builds langs kernel
    builds="${ADM_SRC_DETECTED_BUILDSYS:-}"
    langs="${ADM_SRC_DETECTED_LANGS:-}"
    kernel="${ADM_SRC_DETECTED_KERNEL:-0}"

    if [ "$kernel" = "1" ]; then
        echo "kernel-make"
        return 0
    fi

    # Preferências de build system, na ordem:
    # meson > cmake > autotools > waf > scons > qmake > plain-make > python
    if echo "$builds" | grep -qw "meson"; then
        echo "meson"
        return 0
    fi
    if echo "$builds" | grep -qw "cmake"; then
        echo "cmake"
        return 0
    fi
    if echo "$builds" | grep -qw "autotools"; then
        echo "autotools"
        return 0
    fi
    if echo "$builds" | grep -qw "waf"; then
        echo "waf"
        return 0
    fi
    if echo "$builds" | grep -qw "scons"; then
        echo "scons"
        return 0
    fi
    if echo "$builds" | grep -qw "qmake"; then
        echo "qmake"
        return 0
    fi

    # Se tem Makefile mas nenhum build system detectado -> plain-make
    if find "$workdir" -maxdepth 1 -name 'Makefile' -o -name 'makefile' -type f -print | grep -q . 2>/dev/null; then
        echo "plain-make"
        return 0
    fi

    # Se tem Python setup/pyproject, tenta python
    if [ -f "$workdir/setup.py" ] || [ -f "$workdir/pyproject.toml" ]; then
        echo "python"
        return 0
    fi

    adm_die "Não foi possível detectar uma estratégia de build para o projeto em $workdir. Use hooks específicos."
}

# ----------------------------------------------------------------------
# Helpers de execução padronizada
# ----------------------------------------------------------------------

adm_build_run_in_dir() {
    # Executa comando em diretório com spinner e logs
    # Uso: adm_build_run_in_dir <descrição> <workdir> comando...
    local desc="${1:-}"
    local dir="${2:-}"
    shift 2

    [ -z "$dir" ] && adm_die "adm_build_run_in_dir requer diretório"
    [ -d "$dir" ] || adm_die "Diretório não existe: $dir"

    adm_run_with_spinner "$desc" bash -c "
        set -euo pipefail
        cd \"$dir\"
        \"\$@\"
    " -- "$@"
}

# ----------------------------------------------------------------------
# Implementações de build por estratégia
# ----------------------------------------------------------------------

adm_build_autotools() {
    local category="${1:-}" name="${2:-}" mode="${3:-}" destdir="${4:-}" workdir="${5:-}"

    [ -d "$workdir" ] || adm_die "Workdir inexistente em autotools: $workdir"

    local builddir="$workdir/build.adm"
    rm -rf "$builddir" 2>/dev/null || true
    adm_ensure_dir "$builddir"

    local configure_script
    if [ -x "$workdir/configure" ]; then
        configure_script="$workdir/configure"
    else
        adm_die "Projeto autotools sem ./configure em $workdir"
    fi

    local cfg_args="--prefix=/usr"
    [ -n "${ADM_HOST:-}" ]   && cfg_args+=" --host=$ADM_HOST"
    [ -n "${ADM_BUILD:-}" ]  && cfg_args+=" --build=$ADM_BUILD"
    [ -n "${ADM_TARGET:-}" ] && cfg_args+=" --target=$ADM_TARGET"

    adm_hooks_run_stage "$category" "$name" "pre_configure" "$workdir" "$destdir"

    adm_build_run_in_dir "Configure (autotools) $category/$name" "$builddir" \
        "$configure_script" $cfg_args

    adm_hooks_run_stage "$category" "$name" "post_configure" "$workdir" "$destdir"

    adm_hooks_run_stage "$category" "$name" "pre_build" "$workdir" "$destdir"
    adm_build_run_in_dir "Make (autotools) $category/$name" "$builddir" \
        make -j"$(nproc)"
    adm_hooks_run_stage "$category" "$name" "post_build" "$workdir" "$destdir"

    adm_hooks_run_stage "$category" "$name" "pre_install" "$workdir" "$destdir"
    adm_build_run_in_dir "Make install (autotools) $category/$name" "$builddir" \
        make DESTDIR="$destdir" install
    adm_hooks_run_stage "$category" "$name" "post_install" "$workdir" "$destdir"
}

adm_build_cmake() {
    local category="${1:-}" name="${2:-}" mode="${3:-}" destdir="${4:-}" workdir="${5:-}"

    [ -d "$workdir" ] || adm_die "Workdir inexistente em cmake: $workdir"
    command -v cmake >/dev/null 2>&1 || adm_die "cmake não disponível para construir $category/$name."

    local builddir="$workdir/build.adm"
    rm -rf "$builddir" 2>/dev/null || true
    adm_ensure_dir "$builddir"

    local cflags="${CFLAGS:-}"
    local cxxflags="${CXXFLAGS:-}"

    adm_hooks_run_stage "$category" "$name" "pre_configure" "$workdir" "$destdir"

    adm_build_run_in_dir "CMake configure $category/$name" "$workdir" \
        cmake -S "$workdir" -B "$builddir" \
            -DCMAKE_INSTALL_PREFIX=/usr \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_FLAGS="$cflags" \
            -DCMAKE_CXX_FLAGS="$cxxflags"

    adm_hooks_run_stage "$category" "$name" "post_configure" "$workdir" "$destdir"

    adm_hooks_run_stage "$category" "$name" "pre_build" "$workdir" "$destdir"
    adm_build_run_in_dir "CMake build $category/$name" "$workdir" \
        cmake --build "$builddir" -- -j"$(nproc)"
    adm_hooks_run_stage "$category" "$name" "post_build" "$workdir" "$destdir"

    adm_hooks_run_stage "$category" "$name" "pre_install" "$workdir" "$destdir"
    adm_build_run_in_dir "CMake install $category/$name" "$workdir" \
        DESTDIR="$destdir" cmake --install "$builddir"
    adm_hooks_run_stage "$category" "$name" "post_install" "$workdir" "$destdir"
}

adm_build_meson() {
    local category="${1:-}" name="${2:-}" mode="${3:-}" destdir="${4:-}" workdir="${5:-}"

    [ -d "$workdir" ] || adm_die "Workdir inexistente em meson: $workdir"
    command -v meson >/dev/null 2>&1 || adm_die "meson não disponível para construir $category/$name."

    local builddir="$workdir/build.adm"
    rm -rf "$builddir" 2>/dev/null || true
    adm_ensure_dir "$builddir"

    adm_hooks_run_stage "$category" "$name" "pre_configure" "$workdir" "$destdir"

    adm_build_run_in_dir "Meson setup $category/$name" "$workdir" \
        meson setup "$builddir" "$workdir" \
            --prefix=/usr \
            --buildtype=release

    adm_hooks_run_stage "$category" "$name" "post_configure" "$workdir" "$destdir"

    adm_hooks_run_stage "$category" "$name" "pre_build" "$workdir" "$destdir"
    if command -v ninja >/dev/null 2>&1; then
        adm_build_run_in_dir "Meson (ninja) build $category/$name" "$workdir" \
            ninja -C "$builddir" -j"$(nproc)"
    else
        adm_build_run_in_dir "Meson compile $category/$name" "$workdir" \
            meson compile -C "$builddir"
    fi
    adm_hooks_run_stage "$category" "$name" "post_build" "$workdir" "$destdir"

    adm_hooks_run_stage "$category" "$name" "pre_install" "$workdir" "$destdir"
    adm_build_run_in_dir "Meson install $category/$name" "$workdir" \
        DESTDIR="$destdir" meson install -C "$builddir"
    adm_hooks_run_stage "$category" "$name" "post_install" "$workdir" "$destdir"
}

adm_build_plain_make() {
    local category="${1:-}" name="${2:-}" mode="${3:-}" destdir="${4:-}" workdir="${5:-}"

    [ -d "$workdir" ] || adm_die "Workdir inexistente em plain-make: $workdir"
    if ! find "$workdir" -maxdepth 1 -name 'Makefile' -o -name 'makefile' -type f -print | grep -q . 2>/dev/null; then
        adm_die "plain-make selecionado, mas não há Makefile em $workdir"
    fi

    adm_hooks_run_stage "$category" "$name" "pre_build" "$workdir" "$destdir"
    adm_build_run_in_dir "Make (plain) $category/$name" "$workdir" \
        make -j"$(nproc)"
    adm_hooks_run_stage "$category" "$name" "post_build" "$workdir" "$destdir"

    adm_hooks_run_stage "$category" "$name" "pre_install" "$workdir" "$destdir"
    adm_build_run_in_dir "Make install (plain) $category/$name" "$workdir" \
        make DESTDIR="$destdir" install
    adm_hooks_run_stage "$category" "$name" "post_install" "$workdir" "$destdir"
}

adm_build_waf() {
    local category="${1:-}" name="${2:-}" mode="${3:-}" destdir="${4:-}" workdir="${5:-}"

    [ -d "$workdir" ] || adm_die "Workdir inexistente em waf: $workdir"
    command -v python3 >/dev/null 2>&1 || adm_die "python3 não disponível para waf ($category/$name)."

    if [ ! -x "$workdir/waf" ] && [ ! -x "$workdir/wscript" ]; then
        adm_die "Projeto waf sem 'waf' ou 'wscript' executável em $workdir"
    fi

    local waf_cmd
    if [ -x "$workdir/waf" ]; then
        waf_cmd="./waf"
    else
        waf_cmd="python3 wscript"
    fi

    adm_hooks_run_stage "$category" "$name" "pre_configure" "$workdir" "$destdir"
    adm_build_run_in_dir "waf configure $category/$name" "$workdir" \
        $waf_cmd configure --prefix=/usr
    adm_hooks_run_stage "$category" "$name" "post_configure" "$workdir" "$destdir"

    adm_hooks_run_stage "$category" "$name" "pre_build" "$workdir" "$destdir"
    adm_build_run_in_dir "waf build $category/$name" "$workdir" \
        $waf_cmd build -j"$(nproc)"
    adm_hooks_run_stage "$category" "$name" "post_build" "$workdir" "$destdir"

    adm_hooks_run_stage "$category" "$name" "pre_install" "$workdir" "$destdir"
    adm_build_run_in_dir "waf install $category/$name" "$workdir" \
        $waf_cmd install --destdir="$destdir"
    adm_hooks_run_stage "$category" "$name" "post_install" "$workdir" "$destdir"
}

adm_build_scons() {
    local category="${1:-}" name="${2:-}" mode="${3:-}" destdir="${4:-}" workdir="${5:-}"

    [ -d "$workdir" ] || adm_die "Workdir inexistente em scons: $workdir"
    command -v scons >/dev/null 2>&1 || adm_die "scons não disponível para $category/$name."

    adm_hooks_run_stage "$category" "$name" "pre_build" "$workdir" "$destdir"
    adm_build_run_in_dir "scons build $category/$name" "$workdir" \
        scons -j"$(nproc)"
    adm_hooks_run_stage "$category" "$name" "post_build" "$workdir" "$destdir"

    adm_hooks_run_stage "$category" "$name" "pre_install" "$workdir" "$destdir"
    # Muitos projetos usam "scons install" com prefix
    adm_build_run_in_dir "scons install $category/$name" "$workdir" \
        scons install DESTDIR="$destdir" PREFIX=/usr
    adm_hooks_run_stage "$category" "$name" "post_install" "$workdir" "$destdir"
}

adm_build_qmake() {
    local category="${1:-}" name="${2:-}" mode="${3:-}" destdir="${4:-}" workdir="${5:-}"

    [ -d "$workdir" ] || adm_die "Workdir inexistente em qmake: $workdir"
    command -v qmake >/dev/null 2>&1 || adm_die "qmake não disponível para $category/$name."

    adm_hooks_run_stage "$category" "$name" "pre_configure" "$workdir" "$destdir"
    adm_build_run_in_dir "qmake configure $category/$name" "$workdir" \
        qmake PREFIX=/usr
    adm_hooks_run_stage "$category" "$name" "post_configure" "$workdir" "$destdir"

    adm_hooks_run_stage "$category" "$name" "pre_build" "$workdir" "$destdir"
    adm_build_run_in_dir "qmake make $category/$name" "$workdir" \
        make -j"$(nproc)"
    adm_hooks_run_stage "$category" "$name" "post_build" "$workdir" "$destdir"

    adm_hooks_run_stage "$category" "$name" "pre_install" "$workdir" "$destdir"
    adm_build_run_in_dir "qmake make install $category/$name" "$workdir" \
        make INSTALL_ROOT="$destdir" install
    adm_hooks_run_stage "$category" "$name" "post_install" "$workdir" "$destdir"
}

adm_build_python() {
    local category="${1:-}" name="${2:-}" mode="${3:-}" destdir="${4:-}" workdir="${5:-}"

    [ -d "$workdir" ] || adm_die "Workdir inexistente em python: $workdir"
    command -v python3 >/dev/null 2>&1 || adm_die "python3 não disponível para $category/$name."

    # Prioridade: setup.py > pip/pyproject (porque é mais previsível em ambiente LFS/adm)
    if [ -f "$workdir/setup.py" ]; then
        adm_hooks_run_stage "$category" "$name" "pre_build" "$workdir" "$destdir"
        adm_build_run_in_dir "python setup.py build $category/$name" "$workdir" \
            python3 setup.py build
        adm_hooks_run_stage "$category" "$name" "post_build" "$workdir" "$destdir"

        adm_hooks_run_stage "$category" "$name" "pre_install" "$workdir" "$destdir"
        adm_build_run_in_dir "python setup.py install $category/$name" "$workdir" \
            python3 setup.py install --root="$destdir" --prefix=/usr
        adm_hooks_run_stage "$category" "$name" "post_install" "$workdir" "$destdir"
    elif [ -f "$workdir/pyproject.toml" ]; then
        # Tentativa via pip (mais arriscada, mas melhor do que nada)
        command -v pip3 >/dev/null 2>&1 || adm_die "pip3 não disponível para pacote Python $category/$name (pyproject.toml)."
        adm_hooks_run_stage "$category" "$name" "pre_install" "$workdir" "$destdir"
        adm_build_run_in_dir "pip install (pyproject) $category/$name" "$workdir" \
            pip3 install . --prefix=/usr --root="$destdir"
        adm_hooks_run_stage "$category" "$name" "post_install" "$workdir" "$destdir"
    else
        adm_die "Estratégia python selecionada, mas nem setup.py nem pyproject.toml foram encontrados em $workdir."
    fi
}

adm_build_kernel_make() {
    local category="${1:-}" name="${2:-}" mode="${3:-}" destdir="${4:-}" workdir="${5:-}"

    [ -d "$workdir" ] || adm_die "Workdir inexistente em kernel-make: $workdir"

    adm_warn "Construção de kernel é altamente específica; usando pipeline simples padrão. Hooks provavelmente serão necessários."

    adm_hooks_run_stage "$category" "$name" "pre_build" "$workdir" "$destdir"
    adm_build_run_in_dir "make defconfig $category/$name" "$workdir" \
        make defconfig
    adm_build_run_in_dir "make kernel $category/$name" "$workdir" \
        make -j"$(nproc)"
    adm_hooks_run_stage "$category" "$name" "post_build" "$workdir" "$destdir"

    adm_hooks_run_stage "$category" "$name" "pre_install" "$workdir" "$destdir"
    adm_build_run_in_dir "make modules_install $category/$name" "$workdir" \
        make modules_install INSTALL_MOD_PATH="$destdir"
    # Instalar kernel em /boot dentro do destdir – extremamente genérico.
    adm_build_run_in_dir "instalar kernel (copy) $category/$name" "$workdir" \
        bash -c 'mkdir -p "'"$destdir"'/boot" && cp -v arch/*/boot/bzImage "'"$destdir"'/boot/linux-adm"'
    adm_hooks_run_stage "$category" "$name" "post_install" "$workdir" "$destdir"
}

adm_build_run_for_strategy() {
    local strategy="${1:-}"
    local category="${2:-}" name="${3:-}" mode="${4:-}" destdir="${5:-}" workdir="${6:-}"

    case "$strategy" in
        autotools)   adm_build_autotools   "$category" "$name" "$mode" "$destdir" "$workdir" ;;
        cmake)       adm_build_cmake       "$category" "$name" "$mode" "$destdir" "$workdir" ;;
        meson)       adm_build_meson       "$category" "$name" "$mode" "$destdir" "$workdir" ;;
        plain-make)  adm_build_plain_make  "$category" "$name" "$mode" "$destdir" "$workdir" ;;
        waf)         adm_build_waf         "$category" "$name" "$mode" "$destdir" "$workdir" ;;
        scons)       adm_build_scons       "$category" "$name" "$mode" "$destdir" "$workdir" ;;
        qmake)       adm_build_qmake       "$category" "$name" "$mode" "$destdir" "$workdir" ;;
        python)      adm_build_python      "$category" "$name" "$mode" "$destdir" "$workdir" ;;
        kernel-make) adm_build_kernel_make "$category" "$name" "$mode" "$destdir" "$workdir" ;;
        *)
            adm_die "Estratégia de build desconhecida: $strategy (para $category/$name)."
            ;;
    esac
}

# ----------------------------------------------------------------------
# Build de um pacote individual (já com deps resolvidas)
# ----------------------------------------------------------------------

adm_build_get_version() {
    local category="${1:-}" name="${2:-}"
    [ -z "$category" ] && adm_die "adm_build_get_version requer categoria"
    [ -z "$name" ]     && adm_die "adm_build_get_version requer nome"

    local version
    adm_meta_load "$category" "$name"
    version="$(adm_meta_get_var "version")"
    if [ -z "$version" ]; then
        adm_warn "Metafile de $category/$name sem versão; usando 'unknown'."
        version="unknown"
    fi
    printf '%s\n' "$version"
}

adm_build_maybe_from_cache() {
    local category="${1:-}" name="${2:-}" version="${3:-}" destdir="${4:-}"

    if [ "$ADM_BUILD_CACHE_ENABLED" -ne 1 ]; then
        return 1
    fi

    # Só cacheamos se destdir != "/"
    if [ "$destdir" = "/" ]; then
        adm_info "Cache binário ignorado para $category/$name-$version (DESTDIR=/)."
        return 1
    fi

    if ! adm_cache_exists "$category" "$name" "$version"; then
        return 1
    fi
    if ! adm_cache_validate "$category" "$name" "$version"; then
        adm_warn "Cache encontrado para $category/$name-$version, mas inválido; será ignorado."
        return 1
    fi

    adm_info "Extraindo pacote de cache para $destdir: $category/$name-$version"
    adm_cache_extract_to_destdir "$category" "$name" "$version" "$destdir"
    return 0
}

adm_build_store_to_cache() {
    local category="${1:-}" name="${2:-}" version="${3:-}" destdir="${4:-}"

    if [ "$ADM_BUILD_CACHE_ENABLED" -ne 1 ]; then
        return 0
    fi

    # Não arriscamos cachear DESTDIR=/ (evita pacotizar o sistema inteiro).
    if [ "$destdir" = "/" ]; then
        adm_info "Não armazenando em cache porque DESTDIR=/ para $category/$name-$version."
        return 0
    fi

    adm_info "Armazenando build em cache: $category/$name-$version (DESTDIR=$destdir)"
    adm_cache_store_from_destdir "$category" "$name" "$version" "$destdir"
}

adm_build_one() {
    # Constrói APENAS este pacote (sem resolver deps aqui dentro).
    # É chamada internamente após adm_deps_resolve* determinar a ordem.
    #
    # Uso:
    #   adm_build_one categoria nome modo destdir
    #
    local category_raw="${1:-}"
    local name_raw="${2:-}"
    local mode_raw="${3:-build}"
    local destdir_raw="${4:-}"

    [ -z "$category_raw" ] && adm_die "adm_build_one requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_build_one requer nome"

    local category name mode destdir
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"
    mode="$(adm_build_normalize_mode "$mode_raw")"
    destdir="$(adm_build_prepare_destdir "$destdir_raw")"

    local key
    key="$(adm_build_key "$category" "$name")"

    if [ "${ADM_BUILD_DONE[$key]+x}" = "x" ]; then
        adm_info "Já construído nesta sessão: $category/$name (pulando)."
        return 0
    fi

    adm_stage "BUILD $category/$name (mode=$mode, destdir=$destdir)"

    # Carregar versão e verificar cache
    local version
    version="$(adm_build_get_version "$category" "$name")"

    if adm_build_maybe_from_cache "$category" "$name" "$version" "$destdir"; then
        ADM_BUILD_DONE["$key"]=1
        return 0
    fi

    # Hooks pre_fetch + download/extract + post_fetch
    adm_hooks_run_stage "$category" "$name" "pre_fetch" "" "$destdir"
    adm_src_fetch_for_pkg "$category" "$name"
    adm_hooks_run_stage "$category" "$name" "post_fetch" "" "$destdir"

    # adm_src_fetch_for_pkg define:
    #   ADM_SRC_CURRENT_WORKDIR  (workdir)
    #   ADM_SRC_DETECTED_*       (buildsys, langs, docs, kernel, pkgs)
    local workdir="${ADM_SRC_CURRENT_WORKDIR:-}"
    [ -z "$workdir" ] && adm_die "ADM_SRC_CURRENT_WORKDIR não definido após fetch de $category/$name."

    # Hooks + patches
    adm_hooks_and_patches_for_stage "$category" "$name" "pre_patch" "$workdir" "$destdir"
    adm_hooks_and_patches_for_stage "$category" "$name" "post_patch" "$workdir" "$destdir"

    # Escolher estratégia e construir
    local strategy
    strategy="$(adm_build_choose_strategy "$workdir")"

    adm_info "Estratégia de build escolhida para $category/$name: $strategy"

    adm_build_run_for_strategy "$strategy" "$category" "$name" "$mode" "$destdir" "$workdir"

    # Cache (se aplicável)
    adm_build_store_to_cache "$category" "$name" "$version" "$destdir"

    ADM_BUILD_DONE["$key"]=1

    adm_info "BUILD OK: $category/$name (mode=$mode, destdir=$destdir)"
}

# ----------------------------------------------------------------------
# Build de pacote + dependências
# ----------------------------------------------------------------------

adm_build_pkg() {
    # API principal: constrói pacote + dependências.
    #
    # Uso:
    #   adm_build_pkg categoria nome modo destdir
    #
    local category_raw="${1:-}"
    local name_raw="${2:-}"
    local mode_raw="${3:-build}"
    local destdir_raw="${4:-}"

    [ -z "$category_raw" ] && adm_die "adm_build_pkg requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_build_pkg requer nome"

    local category name mode dep_mode destdir
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"
    mode="$(adm_build_normalize_mode "$mode_raw")"
    dep_mode="$(adm_build_effective_dep_mode "$mode")"
    destdir="$(adm_build_prepare_destdir "$destdir_raw")"

    adm_build_init_paths

    adm_stage "RESOLVE-DEPS $category/$name (mode=$mode => dep_mode=$dep_mode)"

    local pairs=()

    if [ "$ADM_BUILD_DEPS_ENABLED" -eq 1 ]; then
        # Usa 32-resolver-deps para pegar ordem topológica
        while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            pairs+=("$line")
        done < <(adm_deps_resolve_for_pkg "$category" "$name" "$dep_mode")
    else
        # Só o próprio pacote
        pairs+=("$category $name")
    fi

    # Construir na ordem
    local p catg pkg
    for p in "${pairs[@]}"; do
        catg="${p%% *}"
        pkg="${p#* }"
        adm_build_one "$catg" "$pkg" "$mode" "$destdir"
    done
}

adm_build_pkg_from_token() {
    # token: "cat/pkg" ou "pkg"
    # modo: build/run/all/stage1/stage2/native
    # destdir: opcional
    local token="${1:-}"
    local mode_raw="${2:-build}"
    local destdir_raw="${3:-}"

    [ -z "$token" ] && adm_die "adm_build_pkg_from_token requer token"

    local pair category name
    pair="$(adm_build_parse_token "$token")"
    category="${pair%% *}"
    name="${pair#* }"

    adm_build_pkg "$category" "$name" "$mode_raw" "$destdir_raw"
}

# Alias de compatibilidade para scripts antigos
adm_build_engine_build() {
    adm_build_pkg "$@"
}

# ----------------------------------------------------------------------
# CLI de demonstração
# ----------------------------------------------------------------------

adm_build_usage() {
    cat <<EOF
Uso: $(basename "$0") <comando> [args...]

Comandos:
  build <categoria> <nome> [modo] [destdir]
      - Constrói categoria/nome e dependências.
      - modo: build (padrão), run, all, stage1, stage2, native.
      - destdir: diretório raiz de instalação (padrão: /).

  build-token <token> [modo] [destdir]
      - token: "cat/pkg" ou apenas "pkg".
      - Ex: $(basename "$0") build-token bash build /mnt/rootfs

  help
      - Mostra esta ajuda.

Exemplos:
  $(basename "$0") build sys bash
  $(basename "$0") build dev gcc build /usr/src/adm/rootfs-stage1
  $(basename "$0") build-token bash all /usr/src/adm/rootfs-stage2
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-help}"
    case "$cmd" in
        build)
            if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
                adm_error "Uso: $0 build <categoria> <nome> [modo] [destdir]"
                exit 1
            fi
            catg="$2"
            pkg="$3"
            mode="${4:-build}"
            dest="${5:-/}"
            adm_build_pkg "$catg" "$pkg" "$mode" "$dest"
            ;;
        build-token)
            if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
                adm_error "Uso: $0 build-token <token> [modo] [destdir]"
                exit 1
            fi
            token="$2"
            mode="${3:-build}"
            dest="${4:-/}"
            adm_build_pkg_from_token "$token" "$mode" "$dest"
            ;;
        help|-h|--help)
            adm_build_usage
            ;;
        *)
            adm_error "Comando desconhecido: $cmd"
            adm_build_usage
            exit 1
            ;;
    esac
fi
