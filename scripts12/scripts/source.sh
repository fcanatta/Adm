#!/usr/bin/env bash
# source.sh – Download, extração e DETECÇÃO EXTREMA de fontes para o ADM
#
# Responsabilidades:
#   - Usar o metafile atual (MF_*) para:
#       * baixar todas as fontes (sources=...  sha256sums=... / md5sum=...)
#       * conferir checksums
#       * extrair para /usr/src/adm/build/<name>-<version>/src*
#   - Detectar:
#       * BUILD_SYSTEM  (autotools, cmake, meson, waf, scons, python, cargo, go,
#                        node, kernel, llvm, toolchain, manual)
#       * PRIMARY_LANG  (c, cpp, rust, go, python, java, mixed, etc.)
#       * IS_KERNEL, IS_TOOLCHAIN, IS_LLVM
#       * tipo de docs: doxygen, sphinx, man, gtk-doc
#   - Gerar um plano de build simples:
#       /usr/src/adm/build/<name>-<version>/build.plan
#       com chaves:
#         BUILD_SYSTEM=...
#         PRIMARY_LANG=...
#         CONFIGURE_CMD=...
#         BUILD_CMD=...
#         INSTALL_CMD=...
#
# Requer:
#   - metafile.sh carregado (adm_meta_load, MF_*, MF_SOURCES_ARR, MF_SHA256SUMS_ARR etc.)
#
# Uso típico:
#   . /usr/src/adm/scripts/ui.sh
#   . /usr/src/adm/scripts/metafile.sh
#   . /usr/src/adm/scripts/source.sh
#
#   adm_meta_load "/usr/src/adm/repo/apps/bash/metafile" || adm_ui_die "Metafile inválido"
#   adm_source_prepare_from_meta || adm_ui_die "Erro em source"
#
# Este script NÃO usa set -e.

ADM_ROOT="/usr/src/adm"
ADM_DISTFILES_DIR="$ADM_ROOT/distfiles"
ADM_BUILD_ROOT="$ADM_ROOT/build"

# jobs paralelos para download
ADM_SOURCE_JOBS="${ADM_SOURCE_JOBS:-4}"

_SOURCE_HAVE_UI=0
if declare -F adm_ui_log_info >/dev/null 2>&1; then
    _SOURCE_HAVE_UI=1
fi

_src_log() {
    local lvl="$1"; shift || true
    local msg="$*"
    if [ "$_SOURCE_HAVE_UI" -eq 1 ]; then
        case "$lvl" in
            INFO)  adm_ui_log_info  "$msg" ;;
            WARN)  adm_ui_log_warn  "$msg" ;;
            ERROR) adm_ui_log_error "$msg" ;;
            DEBUG) adm_ui_log_info  "[DEBUG] $msg" ;;
            *)     adm_ui_log_info  "$msg" ;;
        esac
    else
        printf 'source[%s]: %s\n' "$lvl" "$msg" >&2
    fi
}

_src_fail() {
    _src_log ERROR "$*"
    return 1
}

_src_trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ------------------------------------------------
# Garantir metafile.sh e estado MF_* carregado
# ------------------------------------------------
_src_ensure_metafile() {
    if declare -F adm_meta_load >/dev/null 2>&1; then
        return 0
    fi
    local mf_script="$ADM_ROOT/scripts/metafile.sh"
    if [ -r "$mf_script" ]; then
        # shellcheck source=/usr/src/adm/scripts/metafile.sh
        . "$mf_script" || _src_fail "Falha ao carregar $mf_script"
        return $?
    fi
    _src_fail "metafile.sh não encontrado em $mf_script"
}

_src_check_mf_loaded() {
    # Verifica se MF_NAME e MF_VERSION existem (metafile carregado)
    if [ -z "${MF_NAME:-}" ] || [ -z "${MF_VERSION:-}" ]; then
        _src_fail "Metafile não parece carregado (MF_NAME/MF_VERSION vazios); chame adm_meta_load antes"
        return 1
    fi
    return 0
}

# ------------------------------------------------
# Diretórios específicos do pacote
# ------------------------------------------------
_src_pkg_build_dir() {
    printf '%s/%s-%s\n' "$ADM_BUILD_ROOT" "$MF_NAME" "$MF_VERSION"
}

_src_pkg_src_dir() {
    local base; base="$(_src_pkg_build_dir)"
    printf '%s/src\n' "$base"
}

_src_pkg_plan_file() {
    local base; base="$(_src_pkg_build_dir)"
    printf '%s/build.plan\n' "$base"
}

# ------------------------------------------------
# Inicialização de diretórios de source
# ------------------------------------------------
adm_source_init_dirs() {
    if ! mkdir -p "$ADM_DISTFILES_DIR" "$ADM_BUILD_ROOT" 2>/dev/null; then
        _src_fail "Não foi possível criar distfiles/build em $ADM_ROOT"
        return 1
    fi

    local bdir; bdir="$(_src_pkg_build_dir)"
    local sdir; sdir="$(_src_pkg_src_dir)"

    if ! mkdir -p "$bdir" "$sdir" 2>/dev/null; then
        _src_fail "Não foi possível criar diretórios de build para $MF_NAME-$MF_VERSION"
        return 1
    fi

    _src_log INFO "Diretórios de build inicializados: $bdir"
    return 0
}

# ------------------------------------------------
# Ferramentas básicas de download
# ------------------------------------------------
_src_have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

_src_choose_http_client() {
    if _src_have_cmd curl; then
        echo "curl"
    elif _src_have_cmd wget; then
        echo "wget"
    else
        echo ""
    fi
}

# ------------------------------------------------
# Nome de arquivo destino para um source
# ------------------------------------------------
_src_distfile_name_for_url() {
    local url="$1"
    local idx="$2"
    local base="${url##*/}"
    [ -z "$base" ] && base="source_$idx"
    # Remove query string
    base="${base%%\?*}"
    echo "$base"
}

# ------------------------------------------------
# Download de um único source
# ------------------------------------------------
_src_download_one() {
    # Uso interno em background:
    #   _src_download_one index url destfile
    local idx="$1"
    local url="$2"
    local dest="$3"

    local client
    local rc=0

    case "$url" in
        git+*|*.git|*://github.com/*|*://gitlab.com/*)
            # Repositório git
            if ! _src_have_cmd git; then
                _src_log ERROR "[download] git não disponível para '$url'"
                return 1
            fi
            # Clona na pasta dest (se existir, atualiza)
            if [ -d "$dest" ]; then
                ( cd "$dest" && git fetch --all --tags --prune ) || return 1
            else
                git clone --depth 1 "$url" "$dest" || return 1
            fi
            ;;
        rsync://*|*::*)
            if ! _src_have_cmd rsync; then
                _src_log ERROR "[download] rsync não disponível para '$url'"
                return 1
            fi
            rsync -av --delete "$url" "$dest" || return 1
            ;;
        ftp://*|http://*|https://*)
            client="$(_src_choose_http_client)"
            if [ -z "$client" ]; then
                _src_log ERROR "[download] curl ou wget não encontrado para '$url'"
                return 1
            fi
            case "$client" in
                curl)
                    curl -L --fail -o "$dest" "$url" || return 1
                    ;;
                wget)
                    wget -O "$dest" "$url" || return 1
                    ;;
            esac
            ;;
        *)
            _src_log WARN "[download] esquema de URL desconhecido, tentando via HTTP genérico: $url"
            client="$(_src_choose_http_client)"
            if [ -z "$client" ]; then
                _src_log ERROR "[download] curl/wget não disponível para '$url'"
                return 1
            fi
            case "$client" in
                curl)
                    curl -L --fail -o "$dest" "$url" || return 1
                    ;;
                wget)
                    wget -O "$dest" "$url" || return 1
                    ;;
            esac
            ;;
    esac

    _src_log INFO "[download] OK [$idx]: $url -> $dest"
    return 0
}

# ------------------------------------------------
# Download de todos os sources do metafile (com paralelismo)
# ------------------------------------------------
adm_source_download_all() {
    _src_ensure_metafile || return 1
    _src_check_mf_loaded || return 1

    if [ "${#MF_SOURCES_ARR[@]}" -eq 0 ]; then
        _src_fail "Metafile não possui MF_SOURCES_ARR populado; rode adm_meta_load corretamente"
        return 1
    fi

    adm_source_init_dirs || return 1

    mkdir -p "$ADM_DISTFILES_DIR" 2>/dev/null || {
        _src_fail "Não foi possível criar $ADM_DISTFILES_DIR"
        return 1
    }

    local pids=()
    local i url dest
    local running=0

    for i in "${!MF_SOURCES_ARR[@]}"; do
        url="${MF_SOURCES_ARR[$i]}"
        dest="$ADM_DISTFILES_DIR/$(_src_distfile_name_for_url "$url" "$i")"

        # já existe; não rebaixa
        if [ -e "$dest" ] || [ -d "$dest" ]; then
            _src_log INFO "[download] já existe, pulando: $dest"
            continue
        fi

        # Se temos UI, podemos rodar com spinner em série.
        # Mas para paralelismo real, vamos background + log normal:
        _src_log INFO "[download] iniciando [$i]: $url"

        _src_download_one "$i" "$url" "$dest" &
        pids+=("$!")
        running=$((running + 1))

        if [ "$running" -ge "$ADM_SOURCE_JOBS" ]; then
            # Espera pelo menos um terminar
            wait "${pids[0]}"
            rc=$?
            if [ "$rc" -ne 0 ]; then
                _src_fail "Falha em download parallelo (pid=${pids[0]})"
                return 1
            fi
            # remove o primeiro da lista
            pids=("${pids[@]:1}")
            running=$((running - 1))
        fi
    done

    # Esperar resto
    local pid rc
    for pid in "${pids[@]}"; do
        wait "$pid"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            _src_fail "Falha em download (pid=$pid)"
            return 1
        fi
    done

    _src_log INFO "Downloads concluídos para $MF_NAME-$MF_VERSION"
    return 0
}

# ------------------------------------------------
# Verificação de checksums
# ------------------------------------------------
adm_source_verify_checksums() {
    _src_ensure_metafile || return 1
    _src_check_mf_loaded || return 1

    local n_sources=${#MF_SOURCES_ARR[@]}
    [ "$n_sources" -gt 0 ] || { _src_fail "Sem sources para verificar"; return 1; }

    adm_source_init_dirs || return 1

    local use_sha=0 use_md5=0
    if [ -n "$MF_SHA256SUMS" ]; then use_sha=1; fi
    if [ -n "$MF_MD5SUM" ]; then use_md5=1; fi

    if [ "$use_sha" -eq 1 ] && [ "$use_md5" -eq 1 ]; then
        _src_fail "Metafile possui sha256sums E md5sum; isso não deveria acontecer"
        return 1
    fi

    local i url fname fpath sum expected

    for i in "${!MF_SOURCES_ARR[@]}"; do
        url="${MF_SOURCES_ARR[$i]}"
        fname="$(_src_distfile_name_for_url "$url" "$i")"
        fpath="$ADM_DISTFILES_DIR/$fname"

        if [ ! -e "$fpath" ] && [ ! -d "$fpath" ]; then
            _src_fail "Arquivo/fonte não encontrado para verificação: $fpath"
            return 1
        fi

        if [ "$use_sha" -eq 1 ]; then
            expected="${MF_SHA256SUMS_ARR[$i]:-}"
            if [ -z "$expected" ]; then
                _src_fail "sha256sum esperado vazio para índice $i"
                return 1
            fi
            if [ -d "$fpath" ]; then
                _src_log WARN "sha256sum não aplicado em diretório git/rsync: $fpath"
                continue
            fi
            if ! _src_have_cmd sha256sum; then
                _src_fail "sha256sum não disponível no sistema"
                return 1
            fi
            sum="$(sha256sum "$fpath" | awk '{print $1}')" || return 1
            if [ "$sum" != "$expected" ]; then
                _src_fail "sha256sum NÃO confere para $fpath (esperado=$expected obtido=$sum)"
                return 1
            fi
            _src_log INFO "sha256sum OK: $fpath"
        elif [ "$use_md5" -eq 1 ]; then
            expected="${MF_MD5SUM_ARR[$i]:-}"
            if [ -z "$expected" ]; then
                _src_fail "md5sum esperado vazio para índice $i"
                return 1
            fi
            if [ -d "$fpath" ]; then
                _src_log WARN "md5sum não aplicado em diretório git/rsync: $fpath"
                continue
            fi
            local md5cmd=""
            if _src_have_cmd md5sum; then
                md5cmd="md5sum"
            elif _src_have_cmd md5; then
                md5cmd="md5"
            else
                _src_fail "md5sum/md5 não disponível no sistema"
                return 1
            fi
            if [ "$md5cmd" = "md5sum" ]; then
                sum="$(md5sum "$fpath" | awk '{print $1}')" || return 1
            else
                sum="$($md5cmd "$fpath" 2>/dev/null | awk '{print $NF}')" || return 1
            fi
            if [ "$sum" != "$expected" ]; then
                _src_fail "md5sum NÃO confere para $fpath (esperado=$expected obtido=$sum)"
                return 1
            fi
            _src_log INFO "md5sum OK: $fpath"
        else
            _src_log WARN "Nenhum checksum definido; NÃO verificando integridade de $fpath"
        fi
    done

    _src_log INFO "Verificação de checksums concluída para $MF_NAME-$MF_VERSION"
    return 0
}

# ------------------------------------------------
# Extração de sources
# ------------------------------------------------
_src_extract_one() {
    local idx="$1"
    local url="$2"

    local fname="$(_src_distfile_name_for_url "$url" "$idx")"
    local src="$ADM_DISTFILES_DIR/$fname"
    local dest="$(_src_pkg_src_dir)/src_$idx"

    mkdir -p "$dest" 2>/dev/null || {
        _src_fail "Falha ao criar diretório de extração: $dest"
        return 1
    }

    # se for diretório (git/rsync), apenas copia (ou bind no futuro)
    if [ -d "$src" ]; then
        _src_log INFO "[extract] copiando diretório $src -> $dest"
        cp -a "$src"/. "$dest"/ || {
            _src_fail "Falha ao copiar diretório $src para $dest"
            return 1
        }
        return 0
    fi

    if [ ! -f "$src" ]; then
        _src_fail "[extract] fonte não encontrado: $src"
        return 1
    fi

    _src_log INFO "[extract] extraindo $src em $dest"

    # Detectar tipo de arquivo
    case "$src" in
        *.tar.gz|*.tgz)
            tar -xzf "$src" -C "$dest" || return 1
            ;;
        *.tar.bz2|*.tbz2)
            tar -xjf "$src" -C "$dest" || return 1
            ;;
        *.tar.xz)
            tar -xJf "$src" -C "$dest" || return 1
            ;;
        *.tar.zst|*.tar.zstd)
            if _src_have_cmd unzstd; then
                unzstd -c "$src" | tar -xf - -C "$dest" || return 1
            elif _src_have_cmd zstd; then
                zstd -d -c "$src" | tar -xf - -C "$dest" || return 1
            else
                _src_fail "Nem unzstd nem zstd disponíveis para $src"
                return 1
            fi
            ;;
        *.zip)
            if ! _src_have_cmd unzip; then
                _src_fail "unzip não disponível para $src"
                return 1
            fi
            unzip -q "$src" -d "$dest" || return 1
            ;;
        *.tar)
            tar -xf "$src" -C "$dest" || return 1
            ;;
        *)
            # arquivo simples (script, patch, etc.)
            cp -a "$src" "$dest"/ || {
                _src_fail "Falha ao copiar $src para $dest"
                return 1
            }
            ;;
    esac

    _src_log INFO "[extract] OK: $src -> $dest"
    return 0
}

adm_source_extract_all() {
    _src_ensure_metafile || return 1
    _src_check_mf_loaded || return 1

    adm_source_init_dirs || return 1

    local i url
    for i in "${!MF_SOURCES_ARR[@]}"; do
        url="${MF_SOURCES_ARR[$i]}"
        if ! _src_extract_one "$i" "$url"; then
            _src_fail "Falha ao extrair source índice $i ($url)"
            return 1
        fi
    done

    _src_log INFO "Extração concluída para $MF_NAME-$MF_VERSION"
    return 0
}
# ------------------------------------------------
# DETECÇÃO: linguagens, kernel, toolchain, build system, docs
# ------------------------------------------------

# Detectar linguagens pelos arquivos
_src_detect_langs() {
    local srcdir="$(_src_pkg_src_dir)"

    if [ ! -d "$srcdir" ]; then
        _src_fail "_src_detect_langs: diretório de fontes não existe: $srcdir"
        return 1
    fi

    local has_c=0 has_cpp=0 has_rust=0 has_go=0 has_py=0 has_java=0 has_js=0
    local has_sh=0

    # limitar profundidade para evitar custos absurdos (mas ainda poderoso)
    while IFS= read -r f; do
        case "$f" in
            *.c)    has_c=1 ;;
            *.cc|*.cpp|*.cxx) has_cpp=1 ;;
            *.rs)   has_rust=1 ;;
            *.go)   has_go=1 ;;
            *.py)   has_py=1 ;;
            *.java) has_java=1 ;;
            *.js)   has_js=1 ;;
            *.sh)   has_sh=1 ;;
        esac
    done < <(find "$srcdir" -maxdepth 6 -type f 2>/dev/null)

    local primary="unknown"
    if [ "$has_c" -eq 1 ] && [ "$has_cpp" -eq 0 ]; then
        primary="c"
    elif [ "$has_cpp" -eq 1 ] && [ "$has_c" -eq 0 ]; then
        primary="cpp"
    elif [ "$has_cpp" -eq 1 ] && [ "$has_c" -eq 1 ]; then
        primary="cpp"
    elif [ "$has_rust" -eq 1 ]; then
        primary="rust"
    elif [ "$has_go" -eq 1 ]; then
        primary="go"
    elif [ "$has_py" -eq 1 ]; then
        primary="python"
    elif [ "$has_java" -eq 1 ]; then
        primary="java"
    elif [ "$has_js" -eq 1 ]; then
        primary="node"
    elif [ "$has_sh" -eq 1 ]; then
        primary="shell"
    fi

    echo "$primary"
    return 0
}

# Detectar kernel / toolchain / llvm por arquivos específicos
_src_detect_special_roles() {
    local srcdir="$(_src_pkg_src_dir)"
    local is_kernel=0 is_toolchain=0 is_llvm=0

    # Verifica se é kernel Linux: Makefile raiz com "Linux kernel"
    if [ -f "$srcdir/Makefile" ]; then
        if grep -qi "Linux kernel" "$srcdir/Makefile" 2>/dev/null; then
            is_kernel=1
        fi
    fi
    if [ "$is_kernel" -eq 0 ]; then
        if find "$srcdir" -maxdepth 2 -name "Kconfig" 2>/dev/null | grep -q .; then
            is_kernel=1
        fi
    fi

    # Toolchain (gcc/binutils/cross/llvm):
    if find "$srcdir" -maxdepth 2 -type d -name "gcc" 2>/dev/null | grep -q .; then
        is_toolchain=1
    fi
    if find "$srcdir" -maxdepth 2 -type d -name "binutils" 2>/dev/null | grep -q .; then
        is_toolchain=1
    fi

    # LLVM / Clang:
    if [ -f "$srcdir/llvm/CMakeLists.txt" ] || [ -f "$srcdir/clang/CMakeLists.txt" ]; then
        is_llvm=1
        is_toolchain=1
    fi
    if [ -f "$srcdir/llvm/CMakeLists.txt" ] || [ -f "$srcdir/llvm/CMakeLists.txt.txt" ]; then
        is_llvm=1
        is_toolchain=1
    fi

    printf '%s %s %s\n' "$is_kernel" "$is_toolchain" "$is_llvm"
    return 0
}

# Detectar sistema de build (autotools, cmake, meson, waf, scons, python, node, etc.)
_src_detect_build_system() {
    local srcdir="$(_src_pkg_src_dir)"
    local system="manual"

    # Procura primeiro em nível raiz e um pouco abaixo
    if [ -f "$srcdir/configure.ac" ] || [ -f "$srcdir/configure.in" ] || [ -x "$srcdir/configure" ]; then
        system="autotools"
    elif [ -f "$srcdir/CMakeLists.txt" ]; then
        system="cmake"
    elif find "$srcdir" -maxdepth 3 -name "meson.build" 2>/dev/null | grep -q .; then
        system="meson"
    elif find "$srcdir" -maxdepth 3 -name "wscript" 2>/dev/null | grep -q .; then
        system="waf"
    elif find "$srcdir" -maxdepth 3 -name "SConstruct" 2>/dev/null | grep -q .; then
        system="scons"
    elif [ -f "$srcdir/setup.py" ] || [ -f "$srcdir/pyproject.toml" ]; then
        system="python"
    elif [ -f "$srcdir/Cargo.toml" ]; then
        system="cargo"
    elif [ -f "$srcdir/go.mod" ] || [ -f "$srcdir/Godeps" ]; then
        system="go"
    elif [ -f "$srcdir/package.json" ]; then
        system="node"
    elif [ -f "$srcdir/Makefile" ] || [ -f "$srcdir/GNUmakefile" ]; then
        system="make"
    fi

    echo "$system"
    return 0
}

# Detectar docs (doxygen, sphinx, man, gtk-doc)
_src_detect_docs() {
    local srcdir="$(_src_pkg_src_dir)"
    local docs=""

    if find "$srcdir" -maxdepth 6 -name "Doxyfile" 2>/dev/null | grep -q .; then
        docs="$docs doxygen"
    fi
    if find "$srcdir" -maxdepth 6 -name "conf.py" -path "*/docs/*" 2>/dev/null | grep -q .; then
        docs="$docs sphinx"
    fi
    if find "$srcdir" -maxdepth 6 -name "gtk-doc.make" 2>/dev/null | grep -q .; then
        docs="$docs gtk-doc"
    fi
    if find "$srcdir" -maxdepth 6 -name "man*" -type d 2>/dev/null | grep -q .; then
        docs="$docs man"
    fi

    docs="$(_src_trim "$docs")"
    echo "$docs"
}

# ------------------------------------------------
# Criar PLANO DE BUILD (build.plan)
# ------------------------------------------------
adm_source_generate_build_plan() {
    _src_ensure_metafile || return 1
    _src_check_mf_loaded || return 1

    local srcdir="$(_src_pkg_src_dir)"
    if [ ! -d "$srcdir" ]; then
        _src_fail "Diretório de fontes não existe para gerar plano: $srcdir"
        return 1
    fi

    local primary_lang
    primary_lang="$(_src_detect_langs)" || return 1

    local is_kernel is_toolchain is_llvm
    read -r is_kernel is_toolchain is_llvm <<< "$(_src_detect_special_roles)" || return 1

    local build_system
    build_system="$(_src_detect_build_system)" || return 1

    local docs
    docs="$(_src_detect_docs)" || return 1

    # Com base no build_system, sugerir comandos padrão
    local configure_cmd="" build_cmd="" install_cmd=""
    local bdir; bdir="$(_src_pkg_build_dir)"

    case "$build_system" in
        autotools)
            configure_cmd="./configure --prefix=/usr"
            build_cmd="make"
            install_cmd="make DESTDIR=\"\${DESTDIR}\" install"
            ;;
        cmake)
            configure_cmd="cmake -B build -S . -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release"
            build_cmd="cmake --build build"
            install_cmd="cmake --install build --prefix \"\${DESTDIR}/usr\""
            ;;
        meson)
            configure_cmd="meson setup build --prefix=/usr"
            build_cmd="ninja -C build"
            install_cmd="ninja -C build install DESTDIR=\"\${DESTDIR}\""
            ;;
        waf)
            configure_cmd="./waf configure --prefix=/usr"
            build_cmd="./waf build"
            install_cmd="./waf install --destdir=\"\${DESTDIR}\""
            ;;
        scons)
            configure_cmd="scons configure"
            build_cmd="scons"
            install_cmd="scons install DESTDIR=\"\${DESTDIR}\""
            ;;
        python)
            if [ -f "$srcdir/pyproject.toml" ]; then
                configure_cmd="pip install . --root \"\${DESTDIR}\" --prefix /usr"
                build_cmd=""  # pip faz tudo
                install_cmd="" # idem
            else
                configure_cmd="python setup.py build"
                build_cmd=""
                install_cmd="python setup.py install --root \"\${DESTDIR}\" --prefix=/usr"
            fi
            ;;
        cargo)
            configure_cmd="cargo build --release"
            build_cmd=""
            install_cmd="install -Dm755 target/release/* -t \"\${DESTDIR}/usr/bin\""
            ;;
        go)
            configure_cmd="go build ./..."
            build_cmd=""
            install_cmd="" # build_core pode instalar binários detectados em ./bin
            ;;
        node)
            configure_cmd="npm install"
            build_cmd="npm run build"
            install_cmd="npm install --global"
            ;;
        make)
            configure_cmd="make"
            build_cmd=""
            install_cmd="make DESTDIR=\"\${DESTDIR}\" install"
            ;;
        manual|*)
            build_system="manual"
            configure_cmd=""
            build_cmd=""
            install_cmd=""
            ;;
    esac

    # kernel / toolchain podem sobrescrever sugestões
    if [ "$is_kernel" -eq 1 ]; then
        build_system="kernel"
        configure_cmd=""             # kernel tem seu próprio fluxo
        build_cmd="make"
        install_cmd="make modules_install INSTALL_MOD_PATH=\"\${DESTDIR}\""
    fi

    if [ "$is_toolchain" -eq 1 ]; then
        # build_core vai aplicar lógica especial baseado em MF_NAME e ADM_TARGET
        case "$MF_NAME" in
            binutils)
                build_system="toolchain-binutils"
                ;;
            gcc)
                build_system="toolchain-gcc"
                ;;
            *)
                build_system="toolchain"
                ;;
        esac
        # comandos genéricos; build_core sobrescreve para passes 1/2
        configure_cmd="./configure"
        build_cmd="make"
        install_cmd="make install"
    fi

    local plan="$(_src_pkg_plan_file)"
    local tmp="${plan}.tmp.$$"

    {
        printf 'NAME=%s\n'           "$MF_NAME"
        printf 'VERSION=%s\n'        "$MF_VERSION"
        printf 'CATEGORY=%s\n'       "$MF_CATEGORY"
        printf 'BUILD_SYSTEM=%s\n'   "$build_system"
        printf 'PRIMARY_LANG=%s\n'   "$primary_lang"
        printf 'IS_KERNEL=%s\n'      "$is_kernel"
        printf 'IS_TOOLCHAIN=%s\n'   "$is_toolchain"
        printf 'IS_LLVM=%s\n'        "$is_llvm"
        printf 'DOCS=%s\n'           "$docs"
        printf 'CONFIGURE_CMD=%s\n'  "$configure_cmd"
        printf 'BUILD_CMD=%s\n'      "$build_cmd"
        printf 'INSTALL_CMD=%s\n'    "$install_cmd"
        printf 'SRC_DIR=%s\n'        "$(_src_pkg_src_dir)"
        printf 'BUILD_DIR=%s\n'      "$(_src_pkg_build_dir)"
    } > "$tmp" 2>/dev/null || {
        _src_fail "Falha ao escrever plano temporário: $tmp"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }

    if ! mv -f "$tmp" "$plan" 2>/dev/null; then
        _src_fail "Falha ao mover plano para destino: $plan"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    _src_log INFO "Plano de build gerado em: $plan (BUILD_SYSTEM=$build_system, LANG=$primary_lang)"
    return 0
}

# ------------------------------------------------
# Função de alto nível: do metafile até o plano
# ------------------------------------------------
adm_source_prepare_from_meta() {
    # Assume que o metafile já foi carregado antes com adm_meta_load.
    _src_ensure_metafile || return 1
    _src_check_mf_loaded || return 1

    if [ "$_SOURCE_HAVE_UI" -eq 1 ]; then
        adm_ui_set_context "source" "$MF_NAME"
        adm_ui_set_log_file "source" "$MF_NAME" || return 1

        adm_ui_with_spinner "Download fontes de $MF_NAME" adm_source_download_all || return 1
        adm_ui_with_spinner "Verificando checksums de $MF_NAME" adm_source_verify_checksums || return 1
        adm_ui_with_spinner "Extraindo fontes de $MF_NAME" adm_source_extract_all || return 1
        adm_ui_with_spinner "Detectando build system de $MF_NAME" adm_source_generate_build_plan || return 1
    else
        adm_source_download_all || return 1
        adm_source_verify_checksums || return 1
        adm_source_extract_all || return 1
        adm_source_generate_build_plan || return 1
    fi

    return 0
}

# Versão que recebe caminho de metafile
adm_source_prepare_from_file() {
    local metafile="$1"
    if [ -z "$metafile" ]; then
        _src_fail "adm_source_prepare_from_file: precisa do caminho do metafile"
        return 1
    fi

    _src_ensure_metafile || return 1
    if ! adm_meta_load "$metafile"; then
        _src_fail "Falha ao carregar metafile: $metafile"
        return 1
    fi

    adm_source_prepare_from_meta
}

# ------------------------------------------------
# Modo de teste direto
# ------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Teste:
    #   ./source.sh /usr/src/adm/repo/apps/bash/metafile
    if [ "$#" -ne 1 ]; then
        echo "Uso: $0 /caminho/para/metafile" >&2
        exit 1
    fi

    mf="$1"
    _src_ensure_metafile || exit 1
    if ! adm_meta_load "$mf"; then
        echo "Falha ao carregar metafile: $mf" >&2
        exit 1
    fi

    if ! adm_source_prepare_from_meta; then
        echo "Erro ao preparar fontes para $MF_NAME-$MF_VERSION" >&2
        exit 1
    fi

    echo "Plano gerado em: $(_src_pkg_plan_file)"
fi
