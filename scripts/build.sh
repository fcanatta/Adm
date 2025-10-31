#!/usr/bin/env bash
#=============================================================
# build.sh — Executor Universal de Builds do ADM Build System
#-------------------------------------------------------------
# Suporte completo a todos os compiladores/sistemas de build:
# autotools, cmake, meson, makefile, python, rust, go, node,
# java, perl, custom (definido no build.pkg)
#=============================================================

set -o pipefail
[[ -n "${ADM_BUILD_SH_LOADED}" ]] && return
ADM_BUILD_SH_LOADED=1

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
source /usr/src/adm/scripts/hooks.sh
source /usr/src/adm/scripts/fetch.sh
source /usr/src/adm/scripts/patch.sh
source /usr/src/adm/scripts/integrity.sh

#-------------------------------------------------------------
#  Configuração
#-------------------------------------------------------------
BUILD_ROOT="${ADM_ROOT}/build"
INSTALL_ROOT="${ADM_ROOT}/install"
BUILD_LOG_DIR="${ADM_LOG_DIR}/build"

ensure_dir "$BUILD_ROOT"
ensure_dir "$INSTALL_ROOT"
ensure_dir "$BUILD_LOG_DIR"

#-------------------------------------------------------------
#  Carregar build.pkg e metadados
#-------------------------------------------------------------
load_build_metadata() {
    local pkg_dir="$1"
    local build_file="${pkg_dir}/build.pkg"

    [[ ! -f "$build_file" ]] && abort_build "Arquivo ausente: ${build_file}"
    source "$build_file"

    [[ -z "$PKG_NAME" || -z "$PKG_VERSION" ]] && abort_build "Campos obrigatórios ausentes em ${build_file}"
    : "${BUILD_HINT:=autotools}"
}

#-------------------------------------------------------------
#  Preparar fonte (extração)
#-------------------------------------------------------------
prepare_source_tree() {
    local pkg_dir="$1"
    local src_file="${PKG_URL##*/}"
    local src_path="${ADM_CACHE_SOURCES}/${src_file}"
    local src_dir="${BUILD_ROOT}/${PKG_BUILD_DIR}"

    rm -rf "$src_dir"
    ensure_dir "$BUILD_ROOT"

    log_info "Extraindo fonte: ${src_file}"
    ui_draw_progress "${PKG_NAME}" "extract" 25 0
    tar -xf "$src_path" -C "$BUILD_ROOT" >>"${BUILD_LOG_DIR}/${PKG_NAME}.log" 2>&1 || abort_build "Falha ao extrair ${src_file}"
    ui_draw_progress "${PKG_NAME}" "extract" 100 1

    echo "$src_dir"
}

#-------------------------------------------------------------
#  Função utilitária: executar fase com logs e UI
#-------------------------------------------------------------
run_phase() {
    local phase="$1"
    local cmd="$2"
    local workdir="$3"

    ui_draw_progress "${PKG_NAME}" "${phase}" 40 0
    log_info "Executando fase ${phase}"
    cd "$workdir" || abort_build "Diretório inválido: ${workdir}"

    eval "$cmd" >>"${BUILD_LOG_DIR}/${PKG_NAME}.log" 2>&1
    local status=$?

    if [[ $status -eq 0 ]]; then
        log_success "Fase concluída: ${phase}"
        ui_draw_progress "${PKG_NAME}" "${phase}" 100 1
    else
        log_error "Erro na fase ${phase} (status $status)"
        abort_build "Falha na fase ${phase}"
    fi
}

#-------------------------------------------------------------
#  Funções de build por tipo
#-------------------------------------------------------------

build_autotools() {
    run_phase "configure" "./configure --prefix=/usr" "$1"
    run_phase "compile" "make -j$(nproc)" "$1"
    run_phase "install" "make install DESTDIR=${INSTALL_ROOT}/${PKG_NAME}" "$1"
}

build_makefile() {
    run_phase "compile" "make -j$(nproc)" "$1"
    run_phase "install" "make install DESTDIR=${INSTALL_ROOT}/${PKG_NAME}" "$1"
}

build_cmake() {
    local builddir="$1/build"
    ensure_dir "$builddir"
    run_phase "cmake" "cmake -B build -DCMAKE_INSTALL_PREFIX=/usr" "$1"
    run_phase "compile" "cmake --build build -j$(nproc)" "$1"
    run_phase "install" "cmake --install build --prefix=${INSTALL_ROOT}/${PKG_NAME}" "$1"
}

build_meson() {
    run_phase "setup" "meson setup build --prefix=/usr" "$1"
    run_phase "compile" "meson compile -C build" "$1"
    run_phase "install" "meson install -C build --destdir=${INSTALL_ROOT}/${PKG_NAME}" "$1"
}

build_python() {
    if [[ -f "$1/setup.py" ]]; then
        run_phase "install" "python3 setup.py install --root=${INSTALL_ROOT}/${PKG_NAME}" "$1"
    elif [[ -f "$1/pyproject.toml" ]]; then
        run_phase "install" "pip install . --root=${INSTALL_ROOT}/${PKG_NAME} --prefix=/usr" "$1"
    else
        abort_build "Fonte Python sem setup.py ou pyproject.toml"
    fi
}

build_rust() {
    run_phase "compile" "cargo build --release" "$1"
    run_phase "install" "cargo install --path . --root ${INSTALL_ROOT}/${PKG_NAME}" "$1"
}

build_go() {
    run_phase "compile" "go build -o ${PKG_NAME}" "$1"
    run_phase "install" "install -Dm755 ${PKG_NAME} ${INSTALL_ROOT}/${PKG_NAME}/usr/bin/${PKG_NAME}" "$1"
}

build_node() {
    if [[ -f "$1/package.json" ]]; then
        run_phase "install" "npm install --prefix ${INSTALL_ROOT}/${PKG_NAME}" "$1"
    else
        abort_build "Projeto Node.js sem package.json"
    fi
}

build_java() {
    if [[ -f "$1/build.gradle" ]]; then
        run_phase "compile" "gradle build" "$1"
    elif [[ -f "$1/pom.xml" ]]; then
        run_phase "compile" "mvn package" "$1"
    elif [[ -f "$1/build.xml" ]]; then
        run_phase "compile" "ant build" "$1"
    else
        abort_build "Fonte Java sem build.gradle/pom.xml/build.xml"
    fi
}

build_perl() {
    if [[ -f "$1/Makefile.PL" ]]; then
        run_phase "configure" "perl Makefile.PL" "$1"
        run_phase "compile" "make" "$1"
        run_phase "install" "make install DESTDIR=${INSTALL_ROOT}/${PKG_NAME}" "$1"
    elif [[ -f "$1/Build.PL" ]]; then
        run_phase "configure" "perl Build.PL" "$1"
        run_phase "compile" "./Build" "$1"
        run_phase "install" "./Build install --destdir ${INSTALL_ROOT}/${PKG_NAME}" "$1"
    else
        abort_build "Fonte Perl sem Makefile.PL ou Build.PL"
    fi
}

build_custom() {
    if declare -f custom_build >/dev/null 2>&1; then
        log_info "Executando build customizado via custom_build()"
        custom_build
    else
        abort_build "BUILD_HINT=custom, mas custom_build() não foi definida no build.pkg"
    fi
}

#-------------------------------------------------------------
#  Detecção automática (fallback)
#-------------------------------------------------------------
detect_auto_build() {
    local src_dir="$1"
    if [[ -f "$src_dir/configure" ]]; then
        build_autotools "$src_dir"
    elif [[ -f "$src_dir/CMakeLists.txt" ]]; then
        build_cmake "$src_dir"
    elif [[ -f "$src_dir/meson.build" ]]; then
        build_meson "$src_dir"
    elif [[ -f "$src_dir/setup.py" || -f "$src_dir/pyproject.toml" ]]; then
        build_python "$src_dir"
    elif [[ -f "$src_dir/Cargo.toml" ]]; then
        build_rust "$src_dir"
    elif [[ -f "$src_dir/Makefile.PL" || -f "$src_dir/Build.PL" ]]; then
        build_perl "$src_dir"
    elif [[ -f "$src_dir/package.json" ]]; then
        build_node "$src_dir"
    elif [[ -f "$src_dir/build.gradle" || -f "$src_dir/pom.xml" ]]; then
        build_java "$src_dir"
    elif [[ -f "$src_dir/Makefile" ]]; then
        build_makefile "$src_dir"
    else
        abort_build "Tipo de build não reconhecido — use BUILD_HINT=custom e defina custom_build()."
    fi
}

#-------------------------------------------------------------
#  Pipeline principal
#-------------------------------------------------------------
build_package() {
    local pkg_dir="$1"
    load_build_metadata "$pkg_dir"
    local pkg_label="${PKG_NAME}-${PKG_VERSION}"

    print_section "Iniciando build de ${pkg_label}"
    ui_draw_header "${pkg_label}" "build"

    call_hook "pre-fetch" "$pkg_dir"
    fetch_package "$pkg_dir"
    call_hook "post-fetch" "$pkg_dir"

    call_hook "pre-integrity" "$pkg_dir"
    check_package_integrity "$pkg_dir"
    call_hook "post-integrity" "$pkg_dir"

    call_hook "pre-patch" "$pkg_dir"
    local src_dir
    src_dir=$(prepare_source_tree "$pkg_dir")
    apply_patches "$pkg_dir" "$src_dir"
    call_hook "post-patch" "$pkg_dir"

    call_hook "pre-build" "$pkg_dir"

    case "$BUILD_HINT" in
        autotools)  build_autotools "$src_dir" ;;
        cmake)      build_cmake "$src_dir" ;;
        meson)      build_meson "$src_dir" ;;
        makefile)   build_makefile "$src_dir" ;;
        python)     build_python "$src_dir" ;;
        rust)       build_rust "$src_dir" ;;
        go)         build_go "$src_dir" ;;
        node)       build_node "$src_dir" ;;
        java)       build_java "$src_dir" ;;
        perl)       build_perl "$src_dir" ;;
        custom)     build_custom "$src_dir" ;;
        *)          detect_auto_build "$src_dir" ;;
    esac

    call_hook "post-build" "$pkg_dir"
    call_hook "pre-install" "$pkg_dir"
    call_hook "post-install" "$pkg_dir"

    call_hook "pre-clean" "$pkg_dir"
    rm -rf "$src_dir"
    call_hook "post-clean" "$pkg_dir"

    log_success "✅ Build concluído: ${pkg_label}"
}

#-------------------------------------------------------------
#  Execução principal
#-------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    log_init
    case "$1" in
        --test)
            build_package "/usr/src/adm/repo/core/zlib"
            ;;
        *)
            [[ -z "$1" ]] && abort_build "Uso: build.sh <pkg_dir> ou --test"
            build_package "$1"
            ;;
    esac
    log_close
fi
