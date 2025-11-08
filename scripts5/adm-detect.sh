#!/usr/bin/env sh
# adm-detect.sh — Detector de linguagens, build systems, compiladores e dependências
# POSIX sh; compatível com dash/ash/bash. Zero rede.
set -u
# =========================
# 0) Config e defaults
# =========================
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_LOG_COLOR:=auto}"
: "${ADM_STAGE:=host}"
: "${ADM_PIPELINE:=detect}"

REG_DETECT_DIR="$ADM_ROOT/registry/detect"
REG_PIPE_DIR="$ADM_ROOT/registry/pipeline"
LOG_DIR="$ADM_ROOT/logs/detect"

PKG_NAME=""
PKG_VERSION=""
SRC_DIR=""
METAFILE=""
STAGE_IN=""
PROFILES_IN=""
STRICT=0
WANT_JSON=0
WANT_TSV=0
MAX_DEPTH=0
HINTS=""

# =========================
# 1) Cores + logging fallback
# =========================
_is_tty(){ [ -t 1 ]; }
_color_on=0
_color_setup(){
  if [ "${ADM_LOG_COLOR}" = "never" ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ]; then
    _color_on=0
  elif [ "${ADM_LOG_COLOR}" = "always" ] || _is_tty; then
    _color_on=1
  else
    _color_on=0
  fi
}
_b(){ [ $_color_on -eq 1 ] && printf '\033[1m'; }
_rst(){ [ $_color_on -eq 1 ] && printf '\033[0m'; }
_c_mag(){ [ $_color_on -eq 1 ] && printf '\033[35;1m'; }  # rosa negrito estágio
_c_yel(){ [ $_color_on -eq 1 ] && printf '\033[33;1m'; }  # amarelo negrito path
_c_gry(){ [ $_color_on -eq 1 ] && printf '\033[38;5;244m';}

have_adm_log=0
command -v adm_log_info >/dev/null 2>&1 && have_adm_log=1

_ts(){ date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'; }
_ctx(){
  st="${ADM_STAGE:-host}"; pipe="${ADM_PIPELINE:-detect}"; path="${SRC_DIR:-$PWD}"
  if [ $_color_on -eq 1 ]; then
    printf "("; _c_mag; printf "%s" "$st"; _rst; _c_gry; printf ":%s" "$pipe"; _rst
    printf " path="; _c_yel; printf "%s" "$path"; _rst; printf ")"
  else
    printf "(%s:%s path=%s)" "$st" "$pipe" "$path"
  fi
}
say(){
  lvl="$1"; shift; msg="$*"
  if [ $have_adm_log -eq 1 ]; then
    case "$lvl" in
      INFO)  adm_log_info  "$msg";;
      WARN)  adm_log_warn  "$msg";;
      ERROR) adm_log_error "$msg";;
      STEP)  adm_log_step_start "$msg" >/dev/null;;
      OK)    adm_log_step_ok;;
      DEBUG) adm_log_debug "$msg";;
      *)     adm_log_info "$msg";;
    esac
  else
    _color_setup
    case "$lvl" in
      INFO) t="[INFO]";; WARN) t="[WARN]";; ERROR) t="[ERROR]";; STEP) t="[STEP]";; OK) t="[ OK ]";; DEBUG) t="[DEBUG]";;
      *) t="[$lvl]";;
    esac
    printf "%s [%s] %s %s\n" "$t" "$(_ts)" "$(_ctx)" "$msg"
  fi
}
die(){ say ERROR "$*"; exit 40; }

# =========================
# 2) Util: IO/FS/strings
# =========================
ensure_dirs(){
  for d in "$REG_DETECT_DIR" "$REG_PIPE_DIR" "$LOG_DIR"; do
    [ -d "$d" ] || mkdir -p "$d" || die "não foi possível criar diretório: $d"
  done
}
json_escape(){ printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | awk 'BEGIN{RS="\r";ORS=""}{gsub(/\n/,"\\n");print}'; }
lower(){ printf "%s" "$1" | tr 'A-Z' 'a-z'; }
trim(){ printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
exists(){ [ -e "$1" ]; }
is_dir(){ [ -d "$1" ]; }

# =========================
# 3) Parsing de args e metafile
# =========================
usage(){
  cat <<'EOF'
Uso: adm-detect.sh <srcdir> [opções]
  --name NAME            Override do nome do pacote
  --version VER          Override da versão
  --metafile FILE        Metafile KEY=VALUE (opcional)
  --stage {0|1|2}        Estágio ativo (impacta heurísticas)
  --profile PERF[,..]    Perfis sugeridos (ex.: normal,clang)
  --strict               Trata avisos críticos como erro
  --json                 Gera também registry/detect/<pkg>/detect.json
  --tsv                  Gera também registry/detect/<pkg>/detect.tsv
  --hint KEY=VAL [...]   Dicas (ex.: BUILD_SYSTEM=cmake C_STANDARD=17)
  --max-depth N          Limita profundidade do scanner (0 = sem limite)
EOF
}
parse_args(){
  [ $# -ge 1 ] || { usage; exit 10; }
  SRC_DIR="$1"; shift || true
  [ -d "$SRC_DIR" ] || { say ERROR "srcdir inexistente: $SRC_DIR"; exit 10; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) shift; PKG_NAME="$1";;
      --version) shift; PKG_VERSION="$1";;
      --metafile) shift; METAFILE="$1";;
      --stage) shift; STAGE_IN="$1";;
      --profile) shift; PROFILES_IN="$1";;
      --strict) STRICT=1;;
      --json) WANT_JSON=1;;
      --tsv) WANT_TSV=1;;
      --hint) shift; [ $# -ge 1 ] || die "faltou KEY=VAL após --hint"; HINTS="${HINTS}${HINTS:+ }$1";;
      --max-depth) shift; MAX_DEPTH="$1";;
      -h|--help|help) usage; exit 0;;
      *) say ERROR "argumento desconhecido: $1"; usage; exit 10;;
    esac
    shift || true
  done
  # Metafile opcional
  if [ -n "$METAFILE" ]; then
    [ -f "$METAFILE" ] || { say ERROR "metafile não encontrado: $METAFILE"; exit 10; }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ''|'#'*) continue;;
        NAME=*) [ -z "$PKG_NAME" ] && PKG_NAME="$(printf "%s" "${line#NAME=}")";;
        VERSION=*) [ -z "$PKG_VERSION" ] && PKG_VERSION="$(printf "%s" "${line#VERSION=}")";;
        *) :;;
      esac
    done <"$METAFILE"
  fi
  [ -n "$PKG_NAME" ] || PKG_NAME="$(basename "$SRC_DIR")"
  [ -n "$PKG_VERSION" ] || PKG_VERSION="0"
  [ -n "$STAGE_IN" ] && ADM_STAGE="stage$STAGE_IN"
}

# =========================
# 4) Estado de detecção (acumuladores)
# =========================
LANGS=""                 # lista: c cxx rust go ...
BUILD_PRIMARY=""         # cmake|meson|autotools|make|cargo|gomod|maven|gradle|pip|poetry|npm|pnpm|yarn|zig|scons|ninja
BUILD_ALT=""
BUILD_ENTRY=""
VCS_TYPE="none"
SUBPROJECTS=""
TOP_FILES=""
HAS_TESTS="off"
HAS_DOCS="off"
HAS_EXAMPLES="off"
HAS_SUBMODULES="off"

# padrões/edições
C_STANDARD=""
CXX_STANDARD=""
RUST_EDITION=""
GO_VERSION_MIN=""
PY_REQ=""
NODE_ENGINE=""
JAVA_TARGET=""

# recursos
WANTS_PIE="off"; WANTS_LTO="off"; WANTS_PGO="off"; WANTS_OPENMP="off"; WANTS_SAN="off"
RPATH_POLICY=""

# requisitos
COMPILERS_REQ=""
LINKERS_REQ=""
TOOLING_REQ=""
INTERPRETERS_REQ=""

# dependências
DEPS_BUILD=""; DEPS_RUNTIME=""; DEPS_OPTIONAL=""
FROM_PKGCONFIG=""; FROM_CMAKE_FIND=""; FROM_MESON_DEP=""; FROM_AUTOTOOLS=""; FROM_LANG_MANIFEST=""
HEADERS_REQ=""; LIBS_REQ=""

# Aux
add_unique(){
  # add_unique VAR value
  var="$1"; val="$(trim "$2")"; [ -z "$val" ] && return 0
  eval "cur=\${$var:-}"
  for x in $cur; do [ "$x" = "$val" ] && return 0; done
  eval "$var=\"\$cur${cur:+ }$val\""
}
add_dep_build(){ add_unique DEPS_BUILD "$(lower "$1")"; }
add_dep_runtime(){ add_unique DEPS_RUNTIME "$(lower "$1")"; }
add_dep_optional(){ add_unique DEPS_OPTIONAL "$(lower "$1")"; }

mark_top(){
  f="$1"; base="$(basename "$f")"; add_unique TOP_FILES "$base"
}

# =========================
# 5) Scanner de arquivos
# =========================
FIND_D="-type d \\( -name .git -o -name .svn -o -name .hg -o -name node_modules -o -name .venv -o -name target -o -name build \\) -prune -o"
FIND_M=""
build_find_expr(){
  if [ "${MAX_DEPTH:-0}" -gt 0 ]; then
    FIND_M=" -maxdepth $MAX_DEPTH "
  else
    FIND_M=""
  fi
}
scan_has(){
  # scan_has "filename|pattern"
  pat="$1"; build_find_expr
  # shellcheck disable=SC2086
  eval "find \"\$SRC_DIR\" $FIND_M $FIND_D -type f -name \"$pat\" -print -quit 2>/dev/null" | grep -q .
}
scan_grep(){
  # scan_grep "pattern" "glob"
  pat="$1"; glob="$2"; build_find_expr
  # shellcheck disable=SC2086
  eval "find \"\$SRC_DIR\" $FIND_M $FIND_D -type f -name \"$glob\" -print 2>/dev/null" | \
  xargs -r grep -I -H -n -E "$pat" 2>/dev/null
}

# =========================
# 6) Detect VCS, top files, subprojects
# =========================
detect_layout(){
  say STEP "Layout"
  [ -d "$SRC_DIR/.git" ] && VCS_TYPE="git"
  scan_has "README*" && mark_top "$(eval "find \"$SRC_DIR\" $FIND_M -maxdepth 1 -name 'README*' -print -quit")"
  scan_has "LICENSE*" && mark_top "$(eval "find \"$SRC_DIR\" $FIND_M -maxdepth 1 -name 'LICENSE*' -print -quit")"
  scan_has "configure.ac" && mark_top "$SRC_DIR/configure.ac"
  scan_has "CMakeLists.txt" && mark_top "$SRC_DIR/CMakeLists.txt"
  scan_has "meson.build" && mark_top "$SRC_DIR/meson.build"
  scan_has "Cargo.toml" && mark_top "$SRC_DIR/Cargo.toml"
  scan_has "go.mod" && mark_top "$SRC_DIR/go.mod"
  scan_has "pyproject.toml" && mark_top "$SRC_DIR/pyproject.toml"
  scan_has "package.json" && mark_top "$SRC_DIR/package.json"
  # submodules
  [ -f "$SRC_DIR/.gitmodules" ] && HAS_SUBMODULES="on"
  # heurística simples de subprojects
  SUBPROJECTS="$(eval "find \"$SRC_DIR\" $FIND_M -type f -name 'CMakeLists.txt' -o -name 'meson.build' 2>/dev/null" | wc -l | awk '{print ($1>1) ? \"multi\" : \"single\"}')"
  [ -d "$SRC_DIR/tests" ] && HAS_TESTS="on"
  [ -d "$SRC_DIR/docs" -o -d "$SRC_DIR/doc" ] && HAS_DOCS="on"
  [ -d "$SRC_DIR/examples" ] && HAS_EXAMPLES="on"
  say OK
}

# =========================
# 7) Detect Linguagens
# =========================
detect_langs(){
  say STEP "Linguagens"
  # C/C++
  if scan_has "*.c"; then add_unique LANGS c; fi
  if scan_has "*.[Cc]pp" || scan_has "*.[cC]xx" || scan_has "*.[cC]++" || scan_has "*.cc"; then add_unique LANGS cxx; fi
  # Fortran
  if scan_has "*.[Ff]90" || scan_has "*.[Ff]" || scan_has "*.[Ff]77"; then add_unique LANGS fortran; fi
  # ASM
  if scan_has "*.[sS]" || scan_has "*.[aA][sS][mM]"; then add_unique LANGS asm; fi
  # Rust
  if scan_has "Cargo.toml"; then add_unique LANGS rust; fi
  # Go
  if scan_has "*.go" || scan_has "go.mod"; then add_unique LANGS go; fi
  # CUDA/OpenCL
  if scan_has "*.cu"; then add_unique LANGS cuda; fi
  if scan_grep "CL/cl.h|find_package\\(OpenCL" "*.c*|*.h*|CMakeLists.txt" >/dev/null; then add_unique LANGS opencl; fi
  # Java/Kotlin
  if scan_has "*.java" || scan_has "pom.xml" || scan_has "build.gradle" || scan_has "build.gradle.kts"; then add_unique LANGS java; fi
  if scan_has "*.kt" || scan_has "*.kts"; then add_unique LANGS kotlin; fi
  # C#
  if scan_has "*.csproj" || scan_has "*.sln"; then add_unique LANGS csharp; fi
  # Swift
  if scan_has "*.swift" || scan_has "Package.swift"; then add_unique LANGS swift; fi
  # Zig
  if scan_has "build.zig"; then add_unique LANGS zig; fi
  # Scripts
  if scan_has "*.py" || scan_has "pyproject.toml" || scan_has "setup.py" || scan_has "setup.cfg"; then add_unique LANGS python; fi
  if scan_has "package.json" || scan_has "*.ts" || scan_has "*.js"; then add_unique LANGS node; fi
  if scan_has "*.rb" || scan_has "Gemfile"; then add_unique LANGS ruby; fi
  if scan_has "*.lua"; then add_unique LANGS lua; fi
  if scan_has "*.pl"; then add_unique LANGS perl; fi
  # padrões/edições
  # C/C++ via CMake/Meson/flags
  cm_std="$(scan_grep 'C_STANDARD|CMAKE_C_STANDARD| -std=gnu11| -std=c11' 'CMakeLists.txt|*.cmake|*.c|*.h' | sed -n '1p')"
  [ -n "$cm_std" ] && C_STANDARD="$(printf "%s" "$cm_std" | sed -n 's/.*C_STANDARD[[:space:]]*[:=][[:space:]]*\([0-9][0-9]\).*/\1/p; s/.*-std=\(gnu11\|c11\|c17\).*/\1/p' | head -n1)"
  cxx_std="$(scan_grep 'CXX_STANDARD|CMAKE_CXX_STANDARD| -std=gnu++| -std=c++' 'CMakeLists.txt|*.cmake|*.cpp|*.hpp|*.cc' | sed -n '1p')"
  [ -n "$cxx_std" ] && CXX_STANDARD="$(printf "%s" "$cxx_std" | sed -n 's/.*CXX_STANDARD[[:space:]]*[:=][[:space:]]*\([0-9][0-9]\).*/\1/p; s/.*-std=\(gnu++[0-9][0-9]\|c++[0-9][0-9]\).*/\1/p' | head -n1)"
  # Rust edition
  if [ -f "$SRC_DIR/Cargo.toml" ]; then
    RUST_EDITION="$(sed -n 's/^[[:space:]]*edition[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC_DIR/Cargo.toml" | head -n1)"
  fi
  # Go version
  if [ -f "$SRC_DIR/go.mod" ]; then
    GO_VERSION_MIN="$(sed -n 's/^go[[:space:]]\{1,\}\([0-9][.0-9]*\).*/\1/p' "$SRC_DIR/go.mod" | head -n1)"
  fi
  # Python requires
  if [ -f "$SRC_DIR/pyproject.toml" ]; then
    PY_REQ="$(sed -n 's/^[[:space:]]*requires-python[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC_DIR/pyproject.toml" | head -n1)"
  fi
  # Node engines
  if [ -f "$SRC_DIR/package.json" ]; then
    NODE_ENGINE="$(sed -n 's/.*"engines"[[:space:]]*:[[:space:]]*{[^}]*"node"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC_DIR/package.json" | head -n1)"
  fi
  # Java target
  if [ -f "$SRC_DIR/pom.xml" ]; then
    JAVA_TARGET="$(sed -n 's/.*<maven.compiler.target>\([^<]*\)<.*/\1/p' "$SRC_DIR/pom.xml" | head -n1)"
  elif [ -f "$SRC_DIR/build.gradle" ] || [ -f "$SRC_DIR/build.gradle.kts" ]; then
    JAVA_TARGET="$(grep -E 'targetCompatibility|sourceCompatibility' "$SRC_DIR"/build.gradle* 2>/dev/null | sed -n 's/.*Compatibility[[:space:]]*[=:][[:space:]]*["'\'']\{0,1\}\([^"'\'' ]*\).*/\1/p' | head -n1)"
  fi
  say OK
}

# =========================
# 8) Detect Build Systems
# =========================
detect_build(){
  say STEP "Build system"
  if scan_has "CMakeLists.txt"; then
    BUILD_PRIMARY="cmake"
    BUILD_ENTRY="CMakeLists.txt"
    scan_has "CMakePresets.json" && add_unique BUILD_ALT "cmake-presets"
  fi
  if [ -z "$BUILD_PRIMARY" ] && scan_has "meson.build"; then
    BUILD_PRIMARY="meson"; BUILD_ENTRY="meson.build"
  elif scan_has "meson.build"; then
    add_unique BUILD_ALT meson
  fi
  if [ -z "$BUILD_PRIMARY" ] && (scan_has "configure.ac" || scan_has "configure.in"); then
    BUILD_PRIMARY="autotools"; BUILD_ENTRY="configure.ac"
  elif scan_has "configure.ac" || scan_has "configure.in"; then
    add_unique BUILD_ALT autotools
  fi
  if [ -z "$BUILD_PRIMARY" ] && scan_has "Cargo.toml"; then
    BUILD_PRIMARY="cargo"; BUILD_ENTRY="Cargo.toml"
  elif scan_has "Cargo.toml"; then
    add_unique BUILD_ALT cargo
  fi
  if [ -z "$BUILD_PRIMARY" ] && scan_has "go.mod"; then
    BUILD_PRIMARY="gomod"; BUILD_ENTRY="go.mod"
  elif scan_has "go.mod"; then
    add_unique BUILD_ALT gomod
  fi
  if [ -z "$BUILD_PRIMARY" ] && scan_has "pyproject.toml"; then
    # vamos inferir backend no detect_deps_python
    BUILD_PRIMARY="pip"; BUILD_ENTRY="pyproject.toml"
  elif scan_has "setup.py" || scan_has "setup.cfg"; then
    [ -z "$BUILD_PRIMARY" ] && BUILD_PRIMARY="pip"
    add_unique BUILD_ALT setuptools
  fi
  if [ -z "$BUILD_PRIMARY" ] && scan_has "package.json"; then
    BUILD_PRIMARY="npm"; BUILD_ENTRY="package.json"
  elif scan_has "package.json"; then
    add_unique BUILD_ALT npm
  fi
  if [ -z "$BUILD_PRIMARY" ] && (scan_has "pom.xml" || scan_has "build.gradle" || scan_has "build.gradle.kts"); then
    if scan_has "pom.xml"; then BUILD_PRIMARY="maven"; BUILD_ENTRY="pom.xml"; else BUILD_PRIMARY="gradle"; BUILD_ENTRY="build.gradle"; fi
  fi
  if [ -z "$BUILD_PRIMARY" ] && scan_has "build.zig"; then
    BUILD_PRIMARY="zig"; BUILD_ENTRY="build.zig"
  fi
  if [ -z "$BUILD_PRIMARY" ] && scan_has "SConstruct"; then
    BUILD_PRIMARY="scons"; BUILD_ENTRY="SConstruct"
  fi
  if [ -z "$BUILD_PRIMARY" ] && scan_has "Makefile"; then
    BUILD_PRIMARY="make"; BUILD_ENTRY="Makefile"
  elif scan_has "Makefile"; then
    add_unique BUILD_ALT make
  fi
  if [ -z "$BUILD_PRIMARY" ] && scan_has "build.ninja"; then
    BUILD_PRIMARY="ninja"; BUILD_ENTRY="build.ninja"
  elif scan_has "build.ninja"; then
    add_unique BUILD_ALT ninja
  fi
  [ -z "$BUILD_PRIMARY" ] && { say WARN "build system não identificado — tente --hint BUILD_SYSTEM=cmake|meson|..."; }
  say OK
}

# =========================
# 9) Detect compiladores/tooling/linkers
# =========================
detect_tooling(){
  say STEP "Compiladores e tooling"
  # Compiladores por linguagem presente
  for l in $LANGS; do
    case "$l" in
      c) add_unique COMPILERS_REQ gcc;;
      cxx) add_unique COMPILERS_REQ g++;;
      fortran) add_unique COMPILERS_REQ gfortran;;
      rust) add_unique COMPILERS_REQ rustc; add_unique COMPILERS_REQ cargo;;
      go) add_unique COMPILERS_REQ go;;
      java|kotlin) add_unique COMPILERS_REQ javac;;
      csharp) add_unique COMPILERS_REQ dotnet;;
      swift) add_unique COMPILERS_REQ swiftc;;
      zig) add_unique COMPILERS_REQ zig;;
    esac
  done
  # Tooling pelos sistemas de build
  case "$BUILD_PRIMARY" in
    cmake) add_unique TOOLING_REQ cmake; add_unique TOOLING_REQ ninja;;
    meson) add_unique TOOLING_REQ meson; add_unique TOOLING_REQ ninja;;
    autotools) add_unique TOOLING_REQ autoconf; add_unique TOOLING_REQ automake; add_unique TOOLING_REQ libtool;;
    cargo) :;;
    gomod) :;;
    pip) add_unique INTERPRETERS_REQ python3;;
    npm) add_unique INTERPRETERS_REQ node;;
    maven) add_unique TOOLING_REQ maven;;
    gradle) add_unique TOOLING_REQ gradle;;
    zig) :;;
    scons) add_unique TOOLING_REQ scons;;
    make) :;;
    ninja) add_unique TOOLING_REQ ninja;;
  esac
  # Linkers por preferências no código
  if scan_grep '-fuse-ld=(lld|mold|gold)' '*.cmake|CMakeLists.txt|*.txt|Makefile' >/dev/null; then
    lnk="$(scan_grep '-fuse-ld=(lld|mold|gold)' '*.cmake|CMakeLists.txt|*.txt|Makefile' | sed -n 's/.*-fuse-ld=\([^ ]*\).*/\1/p' | head -n1)"
    [ -n "$lnk" ] && add_unique LINKERS_REQ "$lnk"
  fi
  # Recursos (OpenMP/LTO/PGO/PIE/Sanitizers)
  scan_grep 'find_package\(OpenMP\)|-fopenmp' 'CMakeLists.txt|*.cmake|*.meson|*.c*|*.h*|meson.build|Makefile' >/dev/null && WANTS_OPENMP="on"
  scan_grep '\-flto\b' 'CMakeLists.txt|*.cmake|Makefile|meson.build|*.txt' >/dev/null && WANTS_LTO="on"
  scan_grep 'profile-(generate|use)|-fprofile-' 'CMakeLists.txt|*.cmake|Makefile|meson.build|*.txt' >/dev/null && WANTS_PGO="on"
  scan_grep '\-f(PIC|PIE)\b|\-pie\b' 'CMakeLists.txt|*.cmake|Makefile|meson.build' >/dev/null && WANTS_PIE="on"
  scan_grep 'fsanitize=(address|undefined|thread|memory)' 'CMakeLists.txt|*.cmake|Makefile|meson.build' >/dev/null && WANTS_SAN="on"
  # RPATH
  if scan_grep 'CMAKE_INSTALL_RPATH| -Wl,-rpath' 'CMakeLists.txt|*.cmake|Makefile|meson.build' >/dev/null; then
    RPATH_POLICY="present"
  fi
  say OK
}
# =========================
# 10) Detect de dependências por ecossistema
# =========================
# Normalizador simples (map de cabeçalhos/libs para nomes)
normalize_dep(){
  case "$(lower "$1")" in
    openssl|ssl|crypto|openssl/ssl.h) echo "openssl";;
    zlib|zlib.h) echo "zlib";;
    libcurl|curl|curl/curl.h) echo "libcurl";;
    png|libpng|png.h|libpng16) echo "libpng";;
    jpeg|libjpeg|jpeglib.h) echo "libjpeg";;
    bzip2|bz2|bzlib.h) echo "bzip2";;
    xz|lzma|lzma.h) echo "xz";;
    zstd|zstd.h) echo "zstd";;
    sqlite|sqlite3|sqlite3.h) echo "sqlite3";;
    gtk3|gtk+-3.0) echo "gtk3";;
    sdl2|SDL2/SDL.h) echo "sdl2";;
    xml2|libxml2|libxml/parser.h) echo "libxml2";;
    protobuf|protoc) echo "protobuf";;
    *) echo "$(lower "$1")";;
  esac
}

detect_deps_autotools(){
  # PKG_CHECK_MODULES, AC_CHECK_LIB/HDR
  scan_grep 'PKG_CHECK_MODULES|AC_CHECK_LIB|AC_CHECK_HEADER' 'configure.ac|configure.in|*.m4|*.ac|Makefile.am' | while IFS=: read -r f _ line; do
    case "$line" in
      *PKG_CHECK_MODULES*'['*']'*'['*']'*)
        mods="$(printf "%s" "$line" | sed -n 's/.*PKG_CHECK_MODULES\((\| \|\[)[^]]*]\{1,\}[[:space:]]*,[[:space:]]*\[\([^]]*\)\].*/\2/p' | tr ' ' '\n')"
        for m in $mods; do add_dep_build "$(normalize_dep "$m")"; add_unique FROM_PKGCONFIG "$m"; done;;
      *AC_CHECK_LIB*)
        lib="$(printf "%s" "$line" | sed -n 's/.*AC_CHECK_LIB(\([^,)]*\).*/\1/p')"
        [ -n "$lib" ] && { add_dep_build "$(normalize_dep "$lib")"; add_unique FROM_AUTOTOOLS "$lib"; };;
      *AC_CHECK_HEADER*)
        hdr="$(printf "%s" "$line" | sed -n 's/.*AC_CHECK_HEADER(\([^,)]*\).*/\1/p')"
        [ -n "$hdr" ] && { add_unique HEADERS_REQ "$hdr"; add_dep_build "$(normalize_dep "$hdr")"; add_unique FROM_AUTOTOOLS "$hdr"; };;
    esac
  done
}

detect_deps_cmake(){
  # find_package, pkg_check_modules, target_link_libraries
  scan_grep 'find_package\(|pkg_check_modules\(|target_link_libraries\(' 'CMakeLists.txt|*.cmake' | while IFS=: read -r f _ line; do
    case "$line" in
      *find_package*'('*)
        pkg="$(printf "%s" "$line" | sed -n 's/.*find_package(\([A-Za-z0-9_+-]\{1,\}\).*/\1/p' | head -n1)"
        ver="$(printf "%s" "$line" | sed -n 's/.*find_package([^,]*,[[:space:]]*VERSION[[:space:]]\{1,\}\([^)]*\).*/\1/p' | head -n1)"
        nm="$(normalize_dep "$pkg")"
        add_dep_build "${nm}${ver:+>=$ver}"
        add_unique FROM_CMAKE_FIND "$pkg";;
      *pkg_check_modules*'('*)
        mods="$(printf "%s" "$line" | sed -n 's/.*pkg_check_modules([^,]*,[[:space:]]*\(.*\)).*/\1/p' | tr ' ' '\n')"
        for m in $mods; do add_dep_build "$(normalize_dep "$m")"; add_unique FROM_PKGCONFIG "$m"; done;;
      *target_link_libraries*'('*)
        libs="$(printf "%s" "$line" | sed -n 's/.*target_link_libraries([^)]* \([^)]*\)).*/\1/p' | tr ' ' '\n' | sed 's/[",$]//g')"
        for l in $libs; do case "$l" in -l*) add_unique LIBS_REQ "${l#-l}";; esac; done;;
    esac
  done
}

detect_deps_meson(){
  scan_grep "dependency\(|subproject\(" "meson.build|meson_options.txt" | while IFS=: read -r f _ line; do
    case "$line" in
      *dependency*'('*)
        dep="$(printf "%s" "$line" | sed -n "s/.*dependency([^'\"a-zA-Z0-9_]*['\"]\([^'\"]*\).*/\1/p" | head -n1)"
        ver="$(printf "%s" "$line" | sed -n "s/.*version:[[:space:]]*['\"]\([^'\"]*\).*/\1/p" | head -n1)"
        nm="$(normalize_dep "$dep")"
        add_dep_build "${nm}${ver:+>=$ver}"
        add_unique FROM_MESON_DEP "$dep";;
      *subproject*'('*)
        sp="$(printf "%s" "$line" | sed -n "s/.*subproject([^'\"a-zA-Z0-9_]*['\"]\([^'\"]*\).*/\1/p" | head -n1)"
        [ -n "$sp" ] && add_unique DEPS_BUILD "$sp";;
    esac
  done
}

detect_deps_c_cxx_headers(){
  scan_grep '#include <[^>]*>' '*.c|*.h|*.cc|*.cpp|*.hpp' | sed -n 's/.*#include <\([^>]*\)>.*/\1/p' | while read -r hdr; do
    nm="$(normalize_dep "$hdr")"
    case "$nm" in stdio.h|stdlib.h|string.h|stdint.h|stddef.h|stdio|stdlib|string|stdint|stddef) :;; *) add_unique HEADERS_REQ "$hdr"; add_dep_build "$nm";; esac
  done
  # libs por -l
  scan_grep ' -l[A-Za-z0-9_]+' 'Makefile|CMakeLists.txt|*.cmake' | sed -n 's/.*-l\([A-Za-z0-9_+-]*\).*/\1/p' | while read -r lb; do
    add_unique LIBS_REQ "$lb"
  done
}

detect_deps_rust(){
  [ -f "$SRC_DIR/Cargo.toml" ] || return 0
  # runtime deps
  sed -n '/^\[dependencies\]/,/^\[/{/^\[/!p}' "$SRC_DIR/Cargo.toml" 2>/dev/null | sed -n 's/^\s*\([A-Za-z0-9_\-]\+\).*/\1/p' | while read -r c; do add_dep_runtime "$(normalize_dep "$c")"; done
  # build deps
  sed -n '/^\[build-dependencies\]/,/^\[/{/^\[/!p}' "$SRC_DIR/Cargo.toml" 2>/dev/null | sed -n 's/^\s*\([A-Za-z0-9_\-]\+\).*/\1/p' | while read -r c; do add_dep_build "$(normalize_dep "$c")"; done
  add_unique FROM_LANG_MANIFEST Cargo.toml
}

detect_deps_go(){
  [ -f "$SRC_DIR/go.mod" ] || return 0
  awk '/^require[[:space:]]*\(/{inblk=1;next} inblk && /\)/{inblk=0} inblk||/^require[[:space:]]+[[:graph:]]/{print}' "$SRC_DIR/go.mod" 2>/dev/null | \
  sed -n 's/^require[[:space:]]\{1,\}\([^ ]*\).*/\1/p; s/^[[:space:]]\{1,\}\([^ ]*\).*/\1/p' | while read -r m; do
    add_dep_runtime "$(normalize_dep "$m")"
  done
  add_unique FROM_LANG_MANIFEST go.mod
}

detect_deps_python(){
  if [ -f "$SRC_DIR/pyproject.toml" ]; then
    # backend
    backend="$(sed -n 's/^[[:space:]]*build-backend[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC_DIR/pyproject.toml" | head -n1)"
    [ -n "$backend" ] && add_unique TOOLING_REQ "$backend"
    # deps
    sed -n '/^\[project\]/,/^\[/{/^\[/!p}' "$SRC_DIR/pyproject.toml" 2>/dev/null | sed -n 's/^[[:space:]]*dependencies[[:space:]]*=[[:space:]]*\[\(.*\)\].*/\1/p' | tr ',' '\n' | sed 's/["'\'']//g' | while read -r d; do
      add_dep_runtime "$(normalize_dep "$d")"
    done
    add_unique FROM_LANG_MANIFEST pyproject.toml
  fi
  if [ -f "$SRC_DIR/requirements.txt" ]; then
    sed 's/[#].*$//' "$SRC_DIR/requirements.txt" | sed '/^[[:space:]]*$/d' | while read -r d; do add_dep_runtime "$(normalize_dep "$d")"; done
  fi
}

detect_deps_node(){
  [ -f "$SRC_DIR/package.json" ] || return 0
  # dependencies
  sed -n 's/.*"dependencies"[[:space:]]*:[[:space:]]*{[^}]*}/&/p' "$SRC_DIR/package.json" | tr ',' '\n' | sed -n 's/.*"\(.*\)":[[:space:]]*".*".*/\1/p' | while read -r d; do add_dep_runtime "$(normalize_dep "$d")"; done
  # devDependencies -> build
  sed -n 's/.*"devDependencies"[[:space:]]*:[[:space:]]*{[^}]*}/&/p' "$SRC_DIR/package.json" | tr ',' '\n' | sed -n 's/.*"\(.*\)":[[:space:]]*".*".*/\1/p' | while read -r d; do add_dep_build "$(normalize_dep "$d")"; done
  add_unique FROM_LANG_MANIFEST package.json
}

detect_deps_java(){
  if [ -f "$SRC_DIR/pom.xml" ]; then
    awk '/<dependencies>/{in=1} in&&/<\/dependencies>/{in=0} in{print}' "$SRC_DIR/pom.xml" | \
    sed -n 's/.*<artifactId>\([^<]*\)<.*/\1/p' | while read -r a; do add_dep_runtime "$(normalize_dep "$a")"; done
    add_unique FROM_LANG_MANIFEST pom.xml
  fi
  if [ -f "$SRC_DIR/build.gradle" ] || [ -f "$SRC_DIR/build.gradle.kts" ]; then
    grep -E 'implementation|api|runtimeOnly|compileOnly' "$SRC_DIR"/build.gradle* 2>/dev/null | \
    sed -n 's/.*[ (]["'\'']\([^:"'\'']*\).*/\1/p' | while read -r a; do add_dep_runtime "$(normalize_dep "$a")"; done
  fi
}

detect_all_deps(){
  say STEP "Dependências"
  detect_deps_autotools
  detect_deps_cmake
  detect_deps_meson
  detect_deps_c_cxx_headers
  detect_deps_rust
  detect_deps_go
  detect_deps_python
  detect_deps_node
  detect_deps_java
  say OK
}

# =========================
# 11) Hints e coerência/ajustes
# =========================
apply_hints(){
  for kv in $HINTS; do
    k="$(printf "%s" "$kv" | sed 's/=.*//')"
    v="$(printf "%s" "$kv" | sed 's/^[^=]*=//')"
    case "$k" in
      BUILD_SYSTEM) [ -z "$BUILD_PRIMARY" ] && BUILD_PRIMARY="$(lower "$v")";;
      C_STANDARD) C_STANDARD="$v";;
      CXX_STANDARD) CXX_STANDARD="$v";;
      RUST_EDITION) RUST_EDITION="$v";;
      GO_VERSION_MIN) GO_VERSION_MIN="$v";;
      PYTHON_REQUIRES) PY_REQ="$v";;
      NODE_ENGINE) NODE_ENGINE="$v";;
      JAVA_TARGET) JAVA_TARGET="$v";;
      WANT_LTO) WANTS_LTO="$(lower "$v")";;
      WANT_OPENMP) WANTS_OPENMP="$(lower "$v")";;
      WANT_PGO) WANTS_PGO="$(lower "$v")";;
      WANT_PIE) WANTS_PIE="$(lower "$v")";;
      WANT_SANITIZERS) WANTS_SAN="$(lower "$v")";;
      *) say WARN "hint desconhecido ignorado: $k";;
    esac
  done
}

coherence_checks(){
  # avisos úteis
  [ -n "$CXX_STANDARD" ] && [ -z "$BUILD_PRIMARY" ] && say WARN "C++ padrão informado mas build system não identificado"
  [ "$WANTS_LTO" = "on" ] && [ "${ADM_STAGE:-}" = "stage0" ] && say WARN "LTO desejado em stage0 — pode ser bloqueado pelo toolchain"
  [ -z "$BUILD_PRIMARY" ] && [ $STRICT -eq 1 ] && { say ERROR "build system não identificado (modo --strict)"; exit 30; }
}

# =========================
# 12) Emissão (report/env/json/tsv)
# =========================
write_outputs(){
  ensure_dirs
  outdir="$REG_DETECT_DIR/${PKG_NAME}-${PKG_VERSION}"
  mkdir -p "$outdir" || die "não foi possível criar $outdir"
  report="$outdir/detect.report"
  envout="$REG_PIPE_DIR/${PKG_NAME}-${PKG_VERSION}.detect.env"
  json="$outdir/detect.json"
  tsv="$outdir/detect.tsv"

  say STEP "Escrevendo relatórios"
  {
    echo "PKG_NAME=$PKG_NAME"
    echo "PKG_VERSION=$PKG_VERSION"
    echo "SRC_DIR=$SRC_DIR"
    echo "VCS_TYPE=$VCS_TYPE"
    echo "SUBPROJECTS=$SUBPROJECTS"
    echo "TOP_FILES=$TOP_FILES"
    echo "HAS_TESTS=$HAS_TESTS"
    echo "HAS_DOCS=$HAS_DOCS"
    echo "HAS_EXAMPLES=$HAS_EXAMPLES"
    echo "LANGS=$LANGS"
    echo "BUILD_SYSTEM_PRIMARY=$BUILD_PRIMARY"
    echo "BUILD_SYSTEM_ALT=$BUILD_ALT"
    echo "BUILD_ENTRY=$BUILD_ENTRY"
    echo "C_STANDARD=$C_STANDARD"
    echo "CXX_STANDARD=$CXX_STANDARD"
    echo "RUST_EDITION=$RUST_EDITION"
    echo "GO_VERSION_MIN=$GO_VERSION_MIN"
    echo "PYTHON_REQUIRES=$PY_REQ"
    echo "NODE_ENGINE=$NODE_ENGINE"
    echo "JAVA_TARGET=$JAVA_TARGET"
    echo "WANTS_PIE=$WANTS_PIE"
    echo "WANTS_LTO=$WANTS_LTO"
    echo "WANTS_PGO=$WANTS_PGO"
    echo "WANTS_OPENMP=$WANTS_OPENMP"
    echo "WANTS_SANITIZERS=$WANTS_SAN"
    echo "RPATH_POLICY=$RPATH_POLICY"
    echo "COMPILERS_REQ=$COMPILERS_REQ"
    echo "LINKERS_REQ=$LINKERS_REQ"
    echo "TOOLING_REQ=$TOOLING_REQ"
    echo "INTERPRETERS_REQ=$INTERPRETERS_REQ"
    echo "DEPS_BUILD=$DEPS_BUILD"
    echo "DEPS_RUNTIME=$DEPS_RUNTIME"
    echo "DEPS_OPTIONAL=$DEPS_OPTIONAL"
    echo "HEADERS_REQ=$HEADERS_REQ"
    echo "LIBS_REQ=$LIBS_REQ"
    echo "FROM_PKGCONFIG=$FROM_PKGCONFIG"
    echo "FROM_CMAKE_FIND=$FROM_CMAKE_FIND"
    echo "FROM_MESON_DEP=$FROM_MESON_DEP"
    echo "FROM_AUTOTOOLS=$FROM_AUTOTOOLS"
    echo "FROM_LANG_MANIFEST=$FROM_LANG_MANIFEST"
    echo "TIMESTAMP=$(_ts)"
  } >"$report" || die "falha ao escrever $report"

  # .env resumido (contrato p/ adm-build.sh)
  {
    echo "BUILD_SYSTEM=${BUILD_PRIMARY}"
    case "$BUILD_PRIMARY" in
      cmake)
        echo 'CONFIGURE_CMD=cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release'
        echo 'BUILD_CMD=cmake --build build -j$(nproc)'
        echo 'INSTALL_CMD=cmake --install build'
        echo 'OUT_SUBDIR=build'
        ;;
      meson)
        echo 'CONFIGURE_CMD=meson setup build --buildtype=release'
        echo 'BUILD_CMD=meson compile -C build'
        echo 'INSTALL_CMD=meson install -C build'
        echo 'OUT_SUBDIR=build'
        ;;
      autotools)
        echo 'CONFIGURE_CMD=./configure --prefix=/usr'
        echo 'BUILD_CMD=make -j$(nproc)'
        echo 'INSTALL_CMD=make install DESTDIR="${DESTDIR}"'
        echo 'OUT_SUBDIR=.'
        ;;
      cargo)
        echo 'CONFIGURE_CMD=:'
        echo 'BUILD_CMD=cargo build --release'
        echo 'INSTALL_CMD=cargo install --path . --root "${DESTDIR}/usr"'
        echo 'OUT_SUBDIR=target/release'
        ;;
      gomod)
        echo 'CONFIGURE_CMD=:'
        echo 'BUILD_CMD=go build ./...'
        echo 'INSTALL_CMD=:'
        echo 'OUT_SUBDIR=.'
        ;;
      pip)
        echo 'CONFIGURE_CMD=:'
        echo 'BUILD_CMD=python3 -m build'
        echo 'INSTALL_CMD=pip3 install --no-deps --root "${DESTDIR}" .'
        echo 'OUT_SUBDIR=.'
        ;;
      npm)
        echo 'CONFIGURE_CMD=:'
        echo 'BUILD_CMD=npm ci && npm run build'
        echo 'INSTALL_CMD=:'
        echo 'OUT_SUBDIR=.'
        ;;
      maven)
        echo 'CONFIGURE_CMD=:'
        echo 'BUILD_CMD=mvn -q -DskipTests package'
        echo 'INSTALL_CMD=:'
        echo 'OUT_SUBDIR=.'
        ;;
      gradle)
        echo 'CONFIGURE_CMD=:'
        echo 'BUILD_CMD=gradle build -x test'
        echo 'INSTALL_CMD=:'
        echo 'OUT_SUBDIR=build'
        ;;
      zig)
        echo 'CONFIGURE_CMD=:'
        echo 'BUILD_CMD=zig build -Doptimize=ReleaseFast'
        echo 'INSTALL_CMD=zig build install --prefix "${DESTDIR}/usr"'
        echo 'OUT_SUBDIR=zig-out'
        ;;
      scons)
        echo 'CONFIGURE_CMD=:'
        echo 'BUILD_CMD=scons -j$(nproc)'
        echo 'INSTALL_CMD=:'
        echo 'OUT_SUBDIR=.'
        ;;
      make)
        echo 'CONFIGURE_CMD=:'
        echo 'BUILD_CMD=make -j$(nproc)'
        echo 'INSTALL_CMD=make install DESTDIR="${DESTDIR}"'
        echo 'OUT_SUBDIR=.'
        ;;
      ninja)
        echo 'CONFIGURE_CMD=:'
        echo 'BUILD_CMD=ninja -j$(nproc)'
        echo 'INSTALL_CMD=:'
        echo 'OUT_SUBDIR=.'
        ;;
      *) echo 'CONFIGURE_CMD=:'; echo 'BUILD_CMD=:'; echo 'INSTALL_CMD=:'; echo 'OUT_SUBDIR=.';;
    esac
    # linguagens e padrões
    [ -n "$C_STANDARD" ] && echo "C_STANDARD=$C_STANDARD"
    [ -n "$CXX_STANDARD" ] && echo "CXX_STANDARD=$CXX_STANDARD"
    [ -n "$RUST_EDITION" ] && echo "RUST_EDITION=$RUST_EDITION"
    [ -n "$GO_VERSION_MIN" ] && echo "GO_VERSION_MIN=$GO_VERSION_MIN"
    [ -n "$PY_REQ" ] && echo "PYTHON_REQUIRES=$PY_REQ"
    [ -n "$NODE_ENGINE" ] && echo "NODE_ENGINE=$NODE_ENGINE"
    [ -n "$JAVA_TARGET" ] && echo "JAVA_TARGET=$JAVA_TARGET"
    # recursos
    echo "WANT_LTO=$WANTS_LTO"
    echo "WANT_OPENMP=$WANTS_OPENMP"
    echo "WANT_PGO=$WANTS_PGO"
    echo "WANT_PIE=$WANTS_PIE"
    echo "WANT_SANITIZERS=$WANTS_SAN"
    # deps
    echo "DEPS_BUILD=$DEPS_BUILD"
    echo "DEPS_RUNTIME=$DEPS_RUNTIME"
    echo "DEPS_OPTIONAL=$DEPS_OPTIONAL"
    # auxiliares
    echo "COMPILERS_REQ=$COMPILERS_REQ"
    echo "TOOLING_REQ=$TOOLING_REQ"
    echo "LINKERS_REQ=$LINKERS_REQ"
    echo "INTERPRETERS_REQ=$INTERPRETERS_REQ"
    echo "SRC_DIR=$SRC_DIR"
  } >"$envout" || die "falha ao escrever $envout"

  # JSON opcional (compacto)
  if [ $WANT_JSON -eq 1 ]; then
    {
      printf '{'
      printf '"pkg":{"name":"%s","version":"%s"},' "$(json_escape "$PKG_NAME")" "$(json_escape "$PKG_VERSION")"
      printf '"src":{"dir":"%s","vcs":"%s"},' "$(json_escape "$SRC_DIR")" "$(json_escape "$VCS_TYPE")"
      printf '"build":{"primary":"%s","alt":"%s","entry":"%s"},' "$(json_escape "$BUILD_PRIMARY")" "$(json_escape "$BUILD_ALT")" "$(json_escape "$BUILD_ENTRY")"
      printf '"langs":"%s",' "$(json_escape "$LANGS")"
      printf '"standards":{"c":"%s","cxx":"%s","rust":"%s","go":"%s","py":"%s","node":"%s","java":"%s"},' \
        "$(json_escape "$C_STANDARD")" "$(json_escape "$CXX_STANDARD")" "$(json_escape "$RUST_EDITION")" "$(json_escape "$GO_VERSION_MIN")" "$(json_escape "$PY_REQ")" "$(json_escape "$NODE_ENGINE")" "$(json_escape "$JAVA_TARGET")"
      printf '"features":{"lto":"%s","pgo":"%s","openmp":"%s","pie":"%s","sanitizers":"%s","rpath":"%s"},' \
        "$WANTS_LTO" "$WANTS_PGO" "$WANTS_OPENMP" "$WANTS_PIE" "$WANTS_SAN" "$RPATH_POLICY"
      printf '"req":{"compilers":"%s","linkers":"%s","tooling":"%s","interpreters":"%s"},' \
        "$(json_escape "$COMPILERS_REQ")" "$(json_escape "$LINKERS_REQ")" "$(json_escape "$TOOLING_REQ")" "$(json_escape "$INTERPRETERS_REQ")"
      printf '"deps":{"build":"%s","runtime":"%s","optional":"%s","headers":"%s","libs":"%s"},' \
        "$(json_escape "$DEPS_BUILD")" "$(json_escape "$DEPS_RUNTIME")" "$(json_escape "$DEPS_OPTIONAL")" "$(json_escape "$HEADERS_REQ")" "$(json_escape "$LIBS_REQ")"
      printf '"from":{"pkgconfig":"%s","cmake":"%s","meson":"%s","autotools":"%s","manifest":"%s"},' \
        "$(json_escape "$FROM_PKGCONFIG")" "$(json_escape "$FROM_CMAKE_FIND")" "$(json_escape "$FROM_MESON_DEP")" "$(json_escape "$FROM_AUTOTOOLS")" "$(json_escape "$FROM_LANG_MANIFEST")"
      printf '"flags":{"strict":%s,"stage":"%s","profiles":"%s"},' \
        "$STRICT" "$(json_escape "$ADM_STAGE")" "$(json_escape "$PROFILES_IN")"
      printf '"timestamp":"%s"' "$(json_escape "$(_ts)")"
      printf '}\n'
    } >"$json" || say WARN "falha ao escrever $json"
  fi

  # TSV opcional (flat)
  if [ $WANT_TSV -eq 1 ]; then
    {
      echo "key\tvalue"
      echo "PKG\t$PKG_NAME-$PKG_VERSION"
      echo "BUILD\t$BUILD_PRIMARY"
      echo "LANGS\t$LANGS"
      echo "C_STD\t$C_STANDARD"
      echo "CXX_STD\t$CXX_STANDARD"
      echo "RUST_ED\t$RUST_EDITION"
      echo "GO_MIN\t$GO_VERSION_MIN"
      echo "PY_REQ\t$PY_REQ"
      echo "NODE\t$NODE_ENGINE"
      echo "JAVA\t$JAVA_TARGET"
      echo "LTO\t$WANTS_LTO"
      echo "PGO\t$WANTS_PGO"
      echo "OPENMP\t$WANTS_OPENMP"
      echo "PIE\t$WANTS_PIE"
      echo "SAN\t$WANTS_SAN"
      echo "COMP\t$COMPILERS_REQ"
      echo "LINK\t$LINKERS_REQ"
      echo "TOOL\t$TOOLING_REQ"
      echo "INTP\t$INTERPRETERS_REQ"
      echo "DEPS_B\t$DEPS_BUILD"
      echo "DEPS_R\t$DEPS_RUNTIME"
      echo "DEPS_O\t$DEPS_OPTIONAL"
    } >"$tsv" || say WARN "falha ao escrever $tsv"
  fi
  say OK
}

# =========================
# 13) Fluxo principal
# =========================
main(){
  _color_setup
  parse_args "$@"
  say INFO "pacote: ${PKG_NAME}-${PKG_VERSION}"
  say INFO "srcdir: $SRC_DIR"
  [ -n "$PROFILES_IN" ] && say INFO "perfis sugeridos: $PROFILES_IN"
  [ -n "$STAGE_IN" ] && say INFO "estágio: $STAGE_IN"

  detect_layout
  detect_langs
  detect_build
  detect_tooling
  detect_all_deps
  apply_hints
  coherence_checks
  write_outputs
  say INFO "detecção concluída"
  exit 0
}

main "$@"
