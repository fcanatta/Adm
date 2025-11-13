#!/usr/bin/env bash
# lib/adm/detect.sh
#
# Subsistema de DETECÇÃO do ADM:
#   - Detecta tipo de build (autotools, cmake, meson, cargo, go, npm, etc.)
#   - Detecta linguagens usadas (C, C++, Rust, Go, Python, etc.)
#   - Detecta compiladores, linkers e ferramentas (make, ninja, pkg-config, etc.)
#   - Detecta ferramentas de documentação (doxygen, sphinx, mkdocs, etc.)
#   - Detecta bibliotecas comuns (zlib, openssl, libcurl, sqlite, libxml2, etc.)
#
# Saída das funções principais:
#
#   adm_detect_build_system SRC_DIR
#     → imprime apenas o tipo de build (autotools, cmake, meson, cargo, go, npm,
#        maven, gradle, scons, make, unknown)
#
#   adm_detect_languages SRC_DIR
#     → várias linhas "LANG <Nome>"
#
#   adm_detect_tools SRC_DIR
#     → linhas "COMPILER <nome>", "LINKER <nome>", "TOOL <nome>", "DOC_TOOL <nome>"
#
#   adm_detect_libs SRC_DIR
#     → linhas "LIB <nome>"
#
#   adm_detect_all SRC_DIR
#     → resumo completo, em formato fácil de parsear:
#          build_system=<tipo>
#          lang=<linguagem>
#          compiler=<nome>
#          linker=<nome>
#          tool=<nome>
#          doc_tool=<nome>
#          lib=<nome>
#
# Objetivo: zero erros silenciosos – qualquer problema relevante gera log claro.
#===============================================================================
# Proteção contra múltiplos loads
#===============================================================================
if [ -n "${ADM_DETECT_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
ADM_DETECT_LOADED=1
#===============================================================================
# Dependências: log + core + repo (opcional)
#===============================================================================
if ! command -v adm_log_detect >/dev/null 2>&1; then
    # Fallback se log.sh ainda não foi carregado
    adm_log()         { printf '%s\n' "$*" >&2; }
    adm_log_detect()  { adm_log "[DETECT] $*"; }
    adm_log_info()    { adm_log "[INFO]   $*"; }
    adm_log_warn()    { adm_log "[WARN]   $*"; }
    adm_log_error()   { adm_log "[ERROR]  $*"; }
    adm_log_debug()   { :; }
fi

if command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_core_init_paths
fi

# ADM_REPO_DIR pode ser usado em heurísticas futuras
: "${ADM_REPO_DIR:=${ADM_ROOT:-/usr/src/adm}/repo}"
#===============================================================================
# Helpers internos genéricos
#===============================================================================
adm_detect__trim() {
    # Uso: adm_detect__trim "  abc  " → "abc"
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Verifica se arquivo existe sob SRC_DIR (busca até certa profundidade)
adm_detect__has_file() {
    # args: SRC_DIR filename
    if [ $# -ne 2 ]; then
        adm_log_error "adm_detect__has_file requer 2 argumentos: SRC_DIR NOME_ARQUIVO"
        return 1
    fi
    local dir="$1" name="$2"

    [ -d "$dir" ] || { adm_log_error "adm_detect__has_file: diretório inexistente: %s" "$dir"; return 1; }

    find "$dir" -maxdepth 3 -type f -name "$name" 2>/dev/null | grep -q .
}

# Grep simples em arquivos específicos, ignorando erro se arquivo não existe
adm_detect__grep_files() {
    # uso: adm_detect__grep_files "padrao" file1 file2...
    if [ $# -lt 2 ]; then
        adm_log_error "adm_detect__grep_files requer pelo menos 2 argumentos: PADRÃO ARQUIVOS..."
        return 1
    fi
    local pat="$1"; shift
    local f
    for f in "$@"; do
        [ -f "$f" ] || continue
        if grep -qi -- "$pat" "$f" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Lista arquivos por extensão (limite razoável)
adm_detect__find_by_ext() {
    # uso: adm_detect__find_by_ext SRC_DIR "c|h"
    if [ $# -ne 2 ]; then
        adm_log_error "adm_detect__find_by_ext requer 2 argumentos: SRC_DIR EXT_REGEXP"
        return 1
    fi
    local dir="$1" extre="$2"

    [ -d "$dir" ] || { adm_log_error "adm_detect__find_by_ext: diretório inexistente: %s" "$dir"; return 1; }

    find "$dir" -maxdepth 5 -type f -regextype posix-egrep -regex ".*\.(${extre})" 2>/dev/null
}

# uniq/sort robusto (não falha se sort não existir)
adm_detect__uniq_sorted() {
    if command -v sort >/dev/null 2>&1; then
        sort -u
    else
        adm_log_warn "sort(1) não encontrado; resultados podem conter duplicados e ordem indefinida."
        awk '!seen[$0]++'
    fi
}

#===============================================================================
# DETECÇÃO DE TIPO DE BUILD (score-based)
#===============================================================================

# Cada função de score devolve um número inteiro (0–100).
# Quanto maior, mais provável.

adm_detect__score_autotools() {
    local dir="$1" score=0

    adm_detect__has_file "$dir" "configure.ac" && score=$((score+40))
    adm_detect__has_file "$dir" "configure.in" && score=$((score+30))
    adm_detect__has_file "$dir" "configure"    && score=$((score+20))
    adm_detect__has_file "$dir" "Makefile.am"  && score=$((score+20))

    printf '%s\n' "$score"
}

adm_detect__score_cmake() {
    local dir="$1" score=0

    adm_detect__has_file "$dir" "CMakeLists.txt" && score=$((score+60))
    adm_detect__has_file "$dir" "cmake.sh"       && score=$((score+10))
    adm_detect__has_file "$dir" "CMakeCache.txt" && score=$((score+5))

    printf '%s\n' "$score"
}

adm_detect__score_meson() {
    local dir="$1" score=0

    adm_detect__has_file "$dir" "meson.build"             && score=$((score+60))
    adm_detect__has_file "$dir" "meson_options.txt"       && score=$((score+10))
    adm_detect__has_file "$dir" "meson-logs/meson-log.txt" && score=$((score+5))

    printf '%s\n' "$score"
}

adm_detect__score_scons() {
    local dir="$1" score=0

    adm_detect__has_file "$dir" "SConstruct" && score=$((score+60))
    adm_detect__has_file "$dir" "SConscript" && score=$((score+10))

    printf '%s\n' "$score"
}

adm_detect__score_cargo() {
    local dir="$1" score=0

    adm_detect__has_file "$dir" "Cargo.toml" && score=$((score+70))
    adm_detect__has_file "$dir" "Cargo.lock" && score=$((score+10))

    printf '%s\n' "$score"
}

adm_detect__score_go() {
    local dir="$1" score=0

    adm_detect__has_file "$dir" "go.mod" && score=$((score+50))
    adm_detect__has_file "$dir" "go.sum" && score=$((score+10))

    # Se tiver muitos .go, aumenta confiança
    if adm_detect__find_by_ext "$dir" "go" | head -n1 | grep -q .; then
        score=$((score+10))
    fi

    printf '%s\n' "$score"
}

adm_detect__score_python() {
    local dir="$1" score=0

    adm_detect__has_file "$dir" "pyproject.toml" && score=$((score+60))
    adm_detect__has_file "$dir" "setup.py"       && score=$((score+40))
    adm_detect__has_file "$dir" "setup.cfg"      && score=$((score+10))
    adm_detect__find_by_ext "$dir" "py" | head -n1 | grep -q . && score=$((score+10))

    printf '%s\n' "$score"
}

adm_detect__score_node() {
    local dir="$1" score=0

    adm_detect__has_file "$dir" "package.json"  && score=$((score+50))
    adm_detect__has_file "$dir" "yarn.lock"     && score=$((score+10))
    adm_detect__has_file "$dir" "pnpm-lock.yaml" && score=$((score+10))

    printf '%s\n' "$score"
}

adm_detect__score_java_maven() {
    local dir="$1" score=0

    adm_detect__has_file "$dir" "pom.xml" && score=$((score+60))
    printf '%s\n' "$score"
}

adm_detect__score_java_gradle() {
    local dir="$1" score=0

    adm_detect__has_file "$dir" "build.gradle"      && score=$((score+40))
    adm_detect__has_file "$dir" "build.gradle.kts"  && score=$((score+40))
    printf '%s\n' "$score"
}

adm_detect__score_make() {
    local dir="$1" score=0

    adm_detect__has_file "$dir" "Makefile"    && score=$((score+40))
    adm_detect__has_file "$dir" "makefile"    && score=$((score+20))
    adm_detect__has_file "$dir" "GNUmakefile" && score=$((score+30))

    printf '%s\n' "$score"
}

# Principal: detect build system
adm_detect_build_system() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_detect_build_system requer 1 argumento: SRC_DIR"
        return 1
    fi
    local dir="$1"

    if [ ! -d "$dir" ]; then
        adm_log_error "adm_detect_build_system: diretório não encontrado: %s" "$dir"
        printf 'unknown\n'
        return 1
    fi

    dir="$(adm_detect__trim "$dir")"

    # Calcula scores
    local s_autotools s_cmake s_meson s_scons s_cargo s_go s_py s_node s_maven s_gradle s_make
    s_autotools="$(adm_detect__score_autotools "$dir")"
    s_cmake="$(adm_detect__score_cmake "$dir")"
    s_meson="$(adm_detect__score_meson "$dir")"
    s_scons="$(adm_detect__score_scons "$dir")"
    s_cargo="$(adm_detect__score_cargo "$dir")"
    s_go="$(adm_detect__score_go "$dir")"
    s_py="$(adm_detect__score_python "$dir")"
    s_node="$(adm_detect__score_node "$dir")"
    s_maven="$(adm_detect__score_java_maven "$dir")"
    s_gradle="$(adm_detect__score_java_gradle "$dir")"
    s_make="$(adm_detect__score_make "$dir")"

    local best="unknown" best_score=0

    # Ordem de prioridade em caso de empate:
    # meson > cmake > autotools > cargo > go > python > node > maven > gradle > scons > make
    if [ "$s_meson" -gt "$best_score" ]; then best_score="$s_meson"; best="meson"; fi
    if [ "$s_cmake" -gt "$best_score" ]; then best_score="$s_cmake"; best="cmake"; fi
    if [ "$s_autotools" -gt "$best_score" ]; then best_score="$s_autotools"; best="autotools"; fi
    if [ "$s_cargo" -gt "$best_score" ]; then best_score="$s_cargo"; best="cargo"; fi
    if [ "$s_go" -gt "$best_score" ]; then best_score="$s_go"; best="go"; fi
    if [ "$s_py" -gt "$best_score" ]; then best_score="$s_py"; best="python"; fi
    if [ "$s_node" -gt "$best_score" ]; then best_score="$s_node"; best="node"; fi
    if [ "$s_maven" -gt "$best_score" ]; then best_score="$s_maven"; best="maven"; fi
    if [ "$s_gradle" -gt "$best_score" ]; then best_score="$s_gradle"; best="gradle"; fi
    if [ "$s_scons" -gt "$best_score" ]; then best_score="$s_scons"; best="scons"; fi
    if [ "$s_make" -gt "$best_score" ]; then best_score="$s_make"; best="make"; fi

    if [ "$best_score" -eq 0 ]; then
        adm_log_detect "Nenhum sistema de build claramente identificado em: %s" "$dir"
        printf 'unknown\n'
        return 0
    fi

    adm_log_detect "Sistema de build detectado (%s): score=%s" "$best" "$best_score"
    printf '%s\n' "$best"
    return 0
}

#===============================================================================
# DETECÇÃO DE LINGUAGENS
#===============================================================================

adm_detect_languages() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_detect_languages requer 1 argumento: SRC_DIR"
        return 1
    fi
    local dir="$1"

    if [ ! -d "$dir" ]; then
        adm_log_error "adm_detect_languages: diretório não encontrado: %s" "$dir"
        return 1
    fi

    dir="$(adm_detect__trim "$dir")"

    local -a langs=()
    local files

    # C / C++
    files="$(adm_detect__find_by_ext "$dir" 'c|h' 2>/dev/null || true)"
    if [ -n "$files" ]; then langs+=("C"); fi

    files="$(adm_detect__find_by_ext "$dir" 'cpp|cxx|cc|hpp|hh' 2>/dev/null || true)"
    if [ -n "$files" ]; then langs+=("C++"); fi

    # Rust
    files="$(adm_detect__find_by_ext "$dir" 'rs' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("Rust")

    # Go
    files="$(adm_detect__find_by_ext "$dir" 'go' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("Go")

    # Python
    files="$(adm_detect__find_by_ext "$dir" 'py' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("Python")

    # Perl
    files="$(adm_detect__find_by_ext "$dir" 'pl|pm' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("Perl")

    # Ruby
    files="$(adm_detect__find_by_ext "$dir" 'rb' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("Ruby")

    # Java / Kotlin / Scala
    files="$(adm_detect__find_by_ext "$dir" 'java' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("Java")

    files="$(adm_detect__find_by_ext "$dir" 'kt' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("Kotlin")

    files="$(adm_detect__find_by_ext "$dir" 'scala' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("Scala")

    # Shell
    files="$(adm_detect__find_by_ext "$dir" 'sh|bash' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("Shell")

    # Lua
    files="$(adm_detect__find_by_ext "$dir" 'lua' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("Lua")

    # PHP
    files="$(adm_detect__find_by_ext "$dir" 'php' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("PHP")

    # Haskell
    files="$(adm_detect__find_by_ext "$dir" 'hs' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("Haskell")

    # OCaml
    files="$(adm_detect__find_by_ext "$dir" 'ml|mli' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("OCaml")

    # C#
    files="$(adm_detect__find_by_ext "$dir" 'cs' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("C#")

    # JavaScript / TypeScript
    files="$(adm_detect__find_by_ext "$dir" 'js' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("JavaScript")
    files="$(adm_detect__find_by_ext "$dir" 'ts' 2>/dev/null || true)"
    [ -n "$files" ] && langs+=("TypeScript")

    if [ ${#langs[@]} -eq 0 ]; then
        adm_log_detect "Nenhuma linguagem claramente detectada em: %s" "$dir"
        return 0
    fi

    printf '%s\n' "${langs[@]}" | adm_detect__uniq_sorted | while IFS= read -r l || [ -n "$l" ]; do
        [ -z "$l" ] && continue
        printf 'LANG %s\n' "$l"
    done

    return 0
}

#===============================================================================
# DETECÇÃO DE COMPILADORES, LINKERS, FERRAMENTAS E DOCS
#===============================================================================

adm_detect_tools() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_detect_tools requer 1 argumento: SRC_DIR"
        return 1
    fi
    local dir="$1"

    if [ ! -d "$dir" ]; then
        adm_log_error "adm_detect_tools: diretório não encontrado: %s" "$dir"
        return 1
    fi

    dir="$(adm_detect__trim "$dir")"

    local -a compilers=() linkers=() tools=() docs=()
    local f
    # Arquivos "de build" mais prováveis
    local -a build_files=(
        "$dir/configure.ac"
        "$dir/configure.in"
        "$dir/configure"
        "$dir/Makefile"
        "$dir/Makefile.am"
        "$dir/CMakeLists.txt"
        "$dir/meson.build"
        "$dir/SConstruct"
        "$dir/build.gradle"
        "$dir/build.gradle.kts"
        "$dir/pom.xml"
        "$dir/package.json"
        "$dir/Cargo.toml"
        "$dir/go.mod"
        "$dir/pyproject.toml"
        "$dir/setup.py"
    )

    # Compiladores clássicos
    if adm_detect__grep_files 'gcc' "${build_files[@]}" ; then compilers+=("gcc"); fi
    if adm_detect__grep_files 'g\+\+' "${build_files[@]}" ; then compilers+=("g++"); fi
    if adm_detect__grep_files 'clang' "${build_files[@]}" ; then compilers+=("clang"); fi
    if adm_detect__grep_files 'clang\+\+' "${build_files[@]}" ; then compilers+=("clang++"); fi
    if adm_detect__grep_files 'rustc' "${build_files[@]}" ; then compilers+=("rustc"); fi
    if adm_detect__grep_files 'go build' "${build_files[@]}" ; then compilers+=("go"); fi
    if adm_detect__grep_files 'javac' "${build_files[@]}" ; then compilers+=("javac"); fi
    if adm_detect__grep_files 'kotlinc' "${build_files[@]}" ; then compilers+=("kotlinc"); fi
    if adm_detect__grep_files 'ghc' "${build_files[@]}" ; then compilers+=("ghc"); fi
    if adm_detect__grep_files 'ocamlc' "${build_files[@]}" ; then compilers+=("ocamlc"); fi

    # Linkers
    if adm_detect__grep_files 'ld\.bfd' "${build_files[@]}" ; then linkers+=("ld.bfd"); fi
    if adm_detect__grep_files 'ld\.gold' "${build_files[@]}" ; then linkers+=("ld.gold"); fi
    if adm_detect__grep_files 'ld\.lld' "${build_files[@]}" ; then linkers+=("ld.lld"); fi
    if adm_detect__grep_files 'mold' "${build_files[@]}" ; then linkers+=("mold"); fi

    # Ferramentas de build
    if adm_detect__grep_files 'cmake' "${build_files[@]}" ; then tools+=("cmake"); fi
    if adm_detect__grep_files 'meson' "${build_files[@]}" ; then tools+=("meson"); fi
    if adm_detect__grep_files 'ninja' "${build_files[@]}" ; then tools+=("ninja"); fi
    if adm_detect__grep_files 'scons' "${build_files[@]}" ; then tools+=("scons"); fi
    if adm_detect__grep_files 'pkg-config' "${build_files[@]}" ; then tools+=("pkg-config"); fi
    if adm_detect__grep_files 'pkgconf' "${build_files[@]}" ; then tools+=("pkgconf"); fi
    if adm_detect__grep_files 'autoconf' "${build_files[@]}" ; then tools+=("autoconf"); fi
    if adm_detect__grep_files 'automake' "${build_files[@]}" ; then tools+=("automake"); fi
    if adm_detect__grep_files 'libtool' "${build_files[@]}" ; then tools+=("libtool"); fi
    if adm_detect__grep_files 'maven' "${build_files[@]}" ; then tools+=("maven"); fi
    if adm_detect__grep_files 'gradle' "${build_files[@]}" ; then tools+=("gradle"); fi
    if adm_detect__grep_files 'npm' "${build_files[@]}" ; then tools+=("npm"); fi
    if adm_detect__grep_files 'yarn' "${build_files[@]}" ; then tools+=("yarn"); fi
    if adm_detect__grep_files 'pnpm' "${build_files[@]}" ; then tools+=("pnpm"); fi
    if adm_detect__grep_files 'pytest' "${build_files[@]}" ; then tools+=("pytest"); fi
    if adm_detect__grep_files 'ctest' "${build_files[@]}" ; then tools+=("ctest"); fi
    if adm_detect__grep_files 'ctest' "$dir/CTestTestfile.cmake" 2>/dev/null ; then tools+=("ctest"); fi

    # Ferramentas de doc
    if adm_detect__grep_files 'doxygen' "${build_files[@]}" ; then docs+=("doxygen"); fi
    if adm_detect__grep_files 'sphinx-build' "${build_files[@]}" ; then docs+=("sphinx-build"); fi
    if adm_detect__grep_files 'mkdocs' "${build_files[@]}" ; then docs+=("mkdocs"); fi
    if adm_detect__grep_files 'pandoc' "${build_files[@]}" ; then docs+=("pandoc"); fi
    if adm_detect__grep_files 'asciidoc' "${build_files[@]}" ; then docs+=("asciidoc"); fi
    if adm_detect__grep_files 'help2man' "${build_files[@]}" ; then docs+=("help2man"); fi
    if adm_detect__grep_files 'texi2any' "${build_files[@]}" ; then docs+=("texi2any"); fi
    if adm_detect__grep_files 'latex' "${build_files[@]}" ; then docs+=("latex"); fi

    # Imprime resultados únicos/sort
    if [ ${#compilers[@]} -gt 0 ]; then
        printf '%s\n' "${compilers[@]}" | adm_detect__uniq_sorted | while IFS= read -r c || [ -n "$c" ]; do
            [ -z "$c" ] && continue
            printf 'COMPILER %s\n' "$c"
        done
    fi

    if [ ${#linkers[@]} -gt 0 ]; then
        printf '%s\n' "${linkers[@]}" | adm_detect__uniq_sorted | while IFS= read -r l || [ -n "$l" ]; do
            [ -z "$l" ] && continue
            printf 'LINKER %s\n' "$l"
        done
    fi

    if [ ${#tools[@]} -gt 0 ]; then
        printf '%s\n' "${tools[@]}" | adm_detect__uniq_sorted | while IFS= read -r t || [ -n "$t" ]; do
            [ -z "$t" ] && continue
            printf 'TOOL %s\n' "$t"
        done
    fi

    if [ ${#docs[@]} -gt 0 ]; then
        printf '%s\n' "${docs[@]}" | adm_detect__uniq_sorted | while IFS= read -r d || [ -n "$d" ]; do
            [ -z "$d" ] && continue
            printf 'DOC_TOOL %s\n' "$d"
        done
    fi

    return 0
}

#===============================================================================
# DETECÇÃO DE LIBS
#===============================================================================

# Mapeamento heurístico: padrões → "nomes de pacote/lib" genéricos
adm_detect__lib_patterns() {
    cat <<'EOF'
zlib:zlib
libz:zlib
openssl:openssl
libssl:openssl
libcrypto:openssl
libcurl:curl
curl:curl
libxml2:libxml2
libxslt:libxslt
sqlite3:sqlite
libsqlite3:sqlite
libpcre:pcre
libpcre2:pcre2
libevent:libevent
libexpat:expat
libbz2:bzip2
bzip2:bzip2
xz:xz
liblzma:xz
liblz4:lz4
libzstd:zstd
libdrm:libdrm
libpng:libpng
libjpeg:jpeg
libtiff:tiff
freetype:freetype
harfbuzz:harfbuzz
libuuid:util-linux
libblkid:util-linux
libmount:util-linux
ncurses:ncurses
readline:readline
gmp:gmp
mpfr:mpfr
mpc:mpc
gdbm:gdbm
libedit:libedit
libcap:libcap
libseccomp:libseccomp
pam:pam
systemd:systemd
udev:systemd
EOF
}

adm_detect_libs() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_detect_libs requer 1 argumento: SRC_DIR"
        return 1
    fi
    local dir="$1"

    if [ ! -d "$dir" ]; then
        adm_log_error "adm_detect_libs: diretório não encontrado: %s" "$dir"
        return 1
    fi

    dir="$(adm_detect__trim "$dir")"

    local -a search_files=()
    local f

    # Arquivos onde geralmente aparecem nomes de libs
    for f in \
        "$dir/configure.ac" \
        "$dir/configure.in" \
        "$dir/configure" \
        "$dir/Makefile.am" \
        "$dir/Makefile" \
        "$dir/CMakeLists.txt" \
        "$dir/meson.build" \
        "$dir/SConstruct" \
        "$dir/pom.xml" \
        "$dir/build.gradle" \
        "$dir/build.gradle.kts" \
        "$dir/package.json" \
        "$dir/Cargo.toml" \
        "$dir/go.mod" \
        "$dir/pyproject.toml" \
        "$dir/setup.py"
    do
        [ -f "$f" ] && search_files+=("$f")
    done

    # Se nada disso existir, ainda podemos tentar alguns .pc ou .in
    if [ ${#search_files[@]} -eq 0 ]; then
        while IFS= read -r f || [ -n "$f" ]; do
            search_files+=("$f")
        done <<EOF
$(find "$dir" -maxdepth 3 -type f \( -name "*.pc.in" -o -name "*.pc" -o -name "*.in" \) 2>/dev/null)
EOF
    fi

    if [ ${#search_files[@]} -eq 0 ]; then
        adm_log_detect "Nenhum arquivo típico para detecção de libs em: %s" "$dir"
        return 0
    fi

    local line pattern libname
    local -a libs=()

    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        pattern="${line%%:*}"
        libname="${line#*:}"

        # procura pattern nos arquivos
        if adm_detect__grep_files "$pattern" "${search_files[@]}"; then
            libs+=("$libname")
        fi
    done <<EOF
$(adm_detect__lib_patterns)
EOF

    if [ ${#libs[@]} -eq 0 ]; then
        return 0
    fi

    printf '%s\n' "${libs[@]}" | adm_detect__uniq_sorted | while IFS= read -r l || [ -n "$l" ]; do
        [ -z "$l" ] && continue
        printf 'LIB %s\n' "$l"
    done

    return 0
}

#===============================================================================
# DETECÇÃO COMPLETA – adm_detect_all
#===============================================================================

adm_detect_all() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_detect_all requer 1 argumento: SRC_DIR"
        return 1
    fi
    local dir="$1"

    if [ ! -d "$dir" ]; then
        adm_log_error "adm_detect_all: diretório não encontrado: %s" "$dir"
        return 1
    fi

    dir="$(adm_detect__trim "$dir")"

    # 1) Build system
    local bs
    bs="$(adm_detect_build_system "$dir" 2>/dev/null || printf 'unknown')" || bs="unknown"
    printf 'build_system=%s\n' "$bs"

    # 2) Linguagens
    local langs
    langs="$(adm_detect_languages "$dir" 2>/dev/null || true)"
    if [ -n "$langs" ]; then
        printf '%s\n' "$langs" | while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            # "LANG X"
            case "$line" in
                LANG\ *)
                    printf 'lang=%s\n' "${line#LANG }"
                    ;;
            esac
        done | adm_detect__uniq_sorted
    fi

    # 3) Ferramentas
    local tools_out
    tools_out="$(adm_detect_tools "$dir" 2>/dev/null || true)"

    if [ -n "$tools_out" ]; then
        printf '%s\n' "$tools_out" | while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            case "$line" in
                COMPILER\ *)
                    printf 'compiler=%s\n' "${line#COMPILER }"
                    ;;
                LINKER\ *)
                    printf 'linker=%s\n' "${line#LINKER }"
                    ;;
                TOOL\ *)
                    printf 'tool=%s\n' "${line#TOOL }"
                    ;;
                DOC_TOOL\ *)
                    printf 'doc_tool=%s\n' "${line#DOC_TOOL }"
                    ;;
            esac
        done | adm_detect__uniq_sorted
    fi

    # 4) Libs
    local libs_out
    libs_out="$(adm_detect_libs "$dir" 2>/dev/null || true)"
    if [ -n "$libs_out" ]; then
        printf '%s\n' "$libs_out" | while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            case "$line" in
                LIB\ *)
                    printf 'lib=%s\n' "${line#LIB }"
                    ;;
            esac
        done | adm_detect__uniq_sorted
    fi

    adm_log_detect "Detecção completa realizada para: %s" "$dir"
    return 0
}

#===============================================================================
# Inicialização simples
#===============================================================================

adm_detect_init() {
    adm_log_debug "Subsistema de detecção (detect.sh) carregado."
}

adm_detect_init
