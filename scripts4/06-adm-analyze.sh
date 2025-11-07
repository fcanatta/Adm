#!/usr/bin/env bash
# 06-adm-analyze.part1.sh
# Analisador de source para detectar build system, linguagens, e dependências.
# Requer: 00-adm-config.sh, 01-adm-lib.sh, 04-adm-metafile.sh (opcional, se usar --metafile)
###############################################################################
# Guardas e pré-requisitos
###############################################################################
if [[ -n "${ADM_ANALYZE_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_ANALYZE_LOADED_PART1=1

if [[ -z "${ADM_CONF_LOADED:-}" ]]; then
  echo "ERRO: 06-adm-analyze requer 00-adm-config.sh carregado." >&2
  return 2 2>/dev/null || exit 2
fi
if [[ -z "${ADM_LIB_LOADED:-}" ]]; then
  echo "ERRO: 06-adm-analyze requer 01-adm-lib.sh carregado." >&2
  return 2 2>/dev/null || exit 2
fi

###############################################################################
# Configurações e defaults
###############################################################################
: "${ADM_ANALYZE_MAX_FILES:=25000}"
: "${ADM_ANALYZE_USE_RIPGREP:=auto}"  # auto|true|false
: "${ADM_ANALYZE_EXT_FILTER:=c,cc,cpp,cxx,h,hpp,hh,rs,go,py,js,ts,java,kt,scala,swift,zig,nim,hs,ml,mli,cs,rb,pl,pm,php,cu,cl,s,S,asm,txt,cmake,meson,sh,toml,json,yaml,yml,xml,ini,gradle,csproj,pyproject,lock}"
: "${ADM_PROFILE_DEFAULT:=normal}"

###############################################################################
# Estado interno
###############################################################################
declare -Ag ANZ_META=(
  [name]="" [version]="" [category]="" [profile]="" [metafile]=""
)
declare -Ag ANZ_RESULT=(
  [build_system]="" [build_confidence]="0.0"
)
declare -ag ANZ_BUILD_EVIDENCE=()
declare -ag ANZ_LANGS=()           # linhas: "name|toolchainA|toolchainB|confidence|files"
declare -ag ANZ_TOOL_DEPS=()       # nomes normalizados
declare -ag ANZ_BUILD_DEPS=()
declare -ag ANZ_RUN_DEPS=()
declare -ag ANZ_OPT_DEPS=()
declare -ag ANZ_NOTES=()
declare -ag ANZ_EVIDENCE=()        # linhas: "type|dep|file|line|confidence"

###############################################################################
# Helpers
###############################################################################
anz_err()  { adm_err   "$*"; }
anz_warn() { adm_warn  "$*"; }
anz_info() { adm_log INFO "${ANZ_META[name]:-}" "analyze" "$*"; }

anz_norm_name() {
  # Normaliza nomes comuns de libs/pacotes
  local n="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  case "$n" in
    libz|zlib1) echo "zlib";;
    libpng|libpng16) echo "libpng";;
    libssl|openssl3|openssl11) echo "openssl";;
    libcurl) echo "curl";;
    libxml2) echo "libxml2";;
    jpeg|libjpeg|libjpeg-turbo) echo "jpeg";;
    libsqlite3|sqlite) echo "sqlite3";;
    pcre) echo "pcre";;
    pcre2-*) echo "pcre2";;
    qt5-*) echo "qt5";;
    qt6-*) echo "qt6";;
    *) echo "$n";;
  esac
}

anz_push_unique() {
  # anz_push_unique <array_name> <value>
  local an="$1" val="$2"
  [[ -z "$an" ]] && return 2
  # shellcheck disable=SC1083,SC2140
  eval 'local -a _arr_=( "${'"$an"'[@]}" )'
  local x; for x in "${_arr_[@]}"; do [[ "$x" == "$val" ]] && return 0; done
  # shellcheck disable=SC1083,SC2140
  eval "$an+=(\"\$val\")"
}

anz_has_cmd() { command -v "$1" >/dev/null 2>&1; }

anz_rg_or_grep() {
  # anz_rg_or_grep <pattern> <dir> [--files-with-matches] [--ext csv] [--max N]
  local pattern="$1" dir="$2"; shift 2
  local fwm="" exts="" max="" extra=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --files-with-matches) fwm=1; shift;;
      --ext) exts="$2"; shift 2;;
      --max) max="$2"; shift 2;;
      *) extra+=( "$1" ); shift;;
    esac
  done
  if [[ "$ADM_ANALYZE_USE_RIPGREP" != "false" ]] && anz_has_cmd rg; then
    local args=( -n --no-messages -S )
    [[ -n "$fwm" ]] && args+=( -l )
    [[ -n "$exts" ]] && IFS=',' read -r -a _E <<<"$exts" && for e in "${_E[@]}"; do args+=( -g "*.${e}" ); done
    [[ -n "$max"  ]] && args+=( --max-files-per-process "$max" )
    rg "${args[@]}" "$pattern" "$dir" 2>/dev/null
  else
    # grep + find
    local find_args=( -type f )
    if [[ -n "$exts" ]]; then
      IFS=',' read -r -a _E <<<"$exts"
      local ex_pat="(" first=1
      for e in "${_E[@]}"; do
        if [[ $first -eq 1 ]]; then ex_pat="-name *.$e"; first=0; else ex_pat="$ex_pat -o -name *.$e"; fi
      done
      find_args+=( \( $ex_pat \) )
    fi
    find "$dir" \( -path "*/.git/*" -o -path "*/node_modules/*" -o -path "*/vendor/*" -o -path "*/third_party/*" -o -path "*/__pycache__/*" -o -path "*/build/*" -o -path "*/dist/*" -o -path "*/target/*" -o -path "*/out/*" \) -prune -o "${find_args[@]}" -print 2>/dev/null | \
    { [[ -n "$max" ]] && head -n "$max" || cat; } | \
    xargs -r grep -n -I -s -H -E -- "$pattern" 2>/dev/null | \
    { [[ -n "$fwm" ]] && cut -d: -f1 | sort -u || cat; }
  fi
}

anz_count_files() {
  local dir="$1"
  find "$dir" \( -path "*/.git/*" -o -path "*/node_modules/*" -o -path "*/vendor/*" -o -path "*/third_party/*" -o -path "*/__pycache__/*" -o -path "*/build/*" -o -path "*/dist/*" -o -path "*/target/*" -o -path "*/out/*" \) -prune -o -type f -print 2>/dev/null | wc -l
}

###############################################################################
# Detecção de build system
###############################################################################
adm_analyze_detect_build_system() {
  local src="$1" strict="${2:-false}"
  [[ -d "$src" ]] || { anz_err "detect_build_system: SRC_DIR inválido: $src"; return 1; }

  local found=() score=() ev=()
  local add() { found+=( "$1" ); score+=( "$2" ); ev+=( "$3" ); }

  [[ -f "$src/Cargo.toml"      ]] && add "cargo"   1.00 "Cargo.toml"
  [[ -f "$src/go.mod"          ]] && add "go"      1.00 "go.mod"
  [[ -f "$src/CMakeLists.txt"  ]] && add "cmake"   0.98 "CMakeLists.txt"
  [[ -f "$src/meson.build"     ]] && add "meson"   0.98 "meson.build"
  [[ -f "$src/configure.ac"    || -f "$src/configure.in" || -f "$src/Makefile.am" || -f "$src/aclocal.m4" ]] && add "autotools" 0.95 "configure.ac/in|Makefile.am"
  [[ -f "$src/pyproject.toml"  ]] && add "python"  0.85 "pyproject.toml"
  [[ -f "$src/package.json"    ]] && add "node"    0.85 "package.json"
  [[ -f "$src/pom.xml" || -f "$src/build.gradle" ]] && add "java" 0.80 "pom.xml|build.gradle"
  [[ -n "$(compgen -G "$src/*.csproj")" ]] && add ".net" 0.80 "*.csproj"
  [[ -f "$src/Package.swift"   ]] && add "swift"   0.80 "Package.swift"
  [[ -f "$src/build.zig"       ]] && add "zig"     0.85 "build.zig"
  [[ -f "$src/Makefile" || -f "$src/GNUmakefile" ]] && add "make" 0.60 "Makefile/GNUmakefile"
  [[ -f "$src/dune" || -f "$src/dune-project" || -f "$src/opam" ]] && add "ocaml" 0.70 "dune|opam"
  [[ -n "$(compgen -G "$src/*.cabal")" || -f "$src/stack.yaml" ]] && add "haskell" 0.70 "*.cabal|stack.yaml"
  [[ -n "$(compgen -G "$src/*.nimble")" ]] && add "nim" 0.70 "*.nimble"
  [[ -f "$src/composer.json"   ]] && add "php"     0.70 "composer.json"
  [[ -n "$(compgen -G "$src/dub.*")" ]] && add "dlang" 0.70 "dub.sdl/json"

  if ((${#found[@]}==0)); then
    ANZ_RESULT[build_system]="unknown"
    ANZ_RESULT[build_confidence]="0.0"
    return 0
  fi

  # Seleciona o maior score; em empate, usa prioridade na ordem acima
  local best_i=0 i
  for ((i=1;i<${#found[@]};i++)); do
    (( $(echo "${score[$i]} > ${score[$best_i]}" | bc -l) )) && best_i=$i
  done

  if ((${#found[@]}>1)); then
    # conflito
    local all="${found[*]}"
    if [[ "$strict" == "true" ]]; then
      anz_err "conflito de build systems detectados: ${all}; use --strict=false ou defina no metafile"
      return 4
    else
      anz_warn "múltiplos build systems detectados (${all}); selecionado: ${found[$best_i]}"
      # Reduz confiança
      ANZ_RESULT[build_confidence]="$(
        awk -v s="${score[$best_i]}" 'BEGIN{printf "%.2f", (s*0.7)}'
      )"
    fi
  fi

  if [[ -z "${ANZ_RESULT[build_confidence]}" || "${ANZ_RESULT[build_confidence]}" == "0.0" ]]; then
    ANZ_RESULT[build_confidence]="${score[$best_i]}"
  fi
  ANZ_RESULT[build_system]="${found[$best_i]}"
  anz_push_unique ANZ_BUILD_EVIDENCE "${ev[$best_i]}"
  return 0
}

###############################################################################
# Detecção de linguagens/compiladores
###############################################################################
adm_analyze_detect_languages() {
  local src="$1"
  [[ -d "$src" ]] || { anz_err "detect_languages: SRC_DIR inválido: $src"; return 1; }

  local total files ext pat
  total="$(anz_count_files "$src")"
  (( total == 0 )) && { anz_warn "nenhum arquivo em $src"; return 0; }

  declare -A lang_exts=(
    [C]="c|h"
    [C++]="cc|cpp|cxx|hpp|hh|hxx"
    [Fortran]="f|f90|f95"
    [ASM]="s|S|asm"
    [Rust]="rs"
    [Go]="go"
    [Python]="py"
    [JavaScript]="js"
    [TypeScript]="ts"
    [Java]="java"
    [Kotlin]="kt"
    [Scala]="scala"
    [Swift]="swift"
    [Zig]="zig"
    [Nim]="nim"
    [Haskell]="hs"
    [OCaml]="ml|mli"
    [.NET]="cs|fs"
    [Ruby]="rb"
    [Perl]="pl|pm"
    [PHP]="php"
    [Dart]="dart"
    [CUDA]="cu|cuh"
    [OpenCL]="cl"
  )
  declare -A toolchains=(
    [C]="gcc|clang" [C++]="g++|clang++" [Fortran]="gfortran" [ASM]="as|nasm|yasm"
    [Rust]="cargo|rustc" [Go]="go" [Python]="python3" [JavaScript]="node"
    [TypeScript]="tsc" [Java]="javac|mvn|gradle" [Kotlin]="kotlinc|gradle"
    [Scala]="scalac|sbt" [Swift]="swiftc" [Zig]="zig" [Nim]="nim"
    [Haskell]="ghc|stack|cabal" [OCaml]="ocamlc|dune" [.NET]="dotnet"
    [Ruby]="ruby|bundler" [Perl]="perl|cpanm" [PHP]="php|composer" [Dart]="dart"
    [CUDA]="nvcc" [OpenCL]="opencl"
  )

  local CSV="$ADM_ANALYZE_EXT_FILTER"
  local L
  for L in "${!lang_exts[@]}"; do
    ext="${lang_exts[$L]}"
    files="$(anz_rg_or_grep . "$src" --files-with-matches --ext "$ext" --max "$ADM_ANALYZE_MAX_FILES" | wc -l)"
    (( files > 0 )) || continue
    # confiança simples: proporção + bonus por manifesto
    local conf
    conf=$(awk -v f="$files" -v t="$total" 'BEGIN{c=f/t; if(c>1)c=1; printf "%.2f", (c<0.9?c+0.1:c)}')
    # bonus se houver manifest típico
    case "$L" in
      Rust) [[ -f "$src/Cargo.toml" ]] && conf=$(awk -v c="$conf" 'BEGIN{printf "%.2f", (c+0.1>1?1:c+0.1)}');;
      Go)   [[ -f "$src/go.mod" ]] && conf=$(awk -v c="$conf" 'BEGIN{printf "%.2f", (c+0.1>1?1:c+0.1)}');;
      Python) [[ -f "$src/pyproject.toml" || -f "$src/setup.py" ]] && conf=$(awk -v c="$conf" 'BEGIN{printf "%.2f", (c+0.05>1?1:c+0.05)}');;
      JavaScript|TypeScript) [[ -f "$src/package.json" ]] && conf=$(awk -v c="$conf" 'BEGIN{printf "%.2f", (c+0.05>1?1:c+0.05)}');;
      Java|Kotlin|Scala) [[ -f "$src/pom.xml" || -f "$src/build.gradle" ]] && conf=$(awk -v c="$conf" 'BEGIN{printf "%.2f", (c+0.05>1?1:c+0.05)}');;
    esac
    local tc="${toolchains[$L]:-}"
    ANZ_LANGS+=( "${L}|${tc}|${conf}|${files}" )
  done
  return 0
}

###############################################################################
# Escaneio de manifests (preferencial)
###############################################################################
adm_analyze_scan_manifests() {
  local src="$1"
  [[ -d "$src" ]] || { anz_err "scan_manifests: SRC_DIR inválido: $src"; return 1; }

  # CMake
  if [[ -f "$src/CMakeLists.txt" ]]; then
    local lines
    while IFS= read -r lines; do
      if [[ "$lines" =~ find_package\ *\(\ *([A-Za-z0-9_+-]+) ]]; then
        local dep="$(anz_norm_name "${BASH_REMATCH[1]}")"
        anz_push_unique ANZ_BUILD_DEPS "$dep"
        ANZ_EVIDENCE+=( "build_dep|$dep|CMakeLists.txt|find_package|0.95" )
      fi
      if [[ "$lines" =~ pkg_check_modules\ *\(.+\ +([A-Za-z0-9._+-]+)\ *\) ]]; then
        local dep="$(anz_norm_name "${BASH_REMATCH[1]}")"
        anz_push_unique ANZ_BUILD_DEPS "$dep"
        anz_push_unique ANZ_TOOL_DEPS "pkg-config"
        ANZ_EVIDENCE+=( "build_dep|$dep|CMakeLists.txt|pkg_check_modules|0.90" )
      fi
      if [[ "$lines" =~ option\ *\(\ *([A-Za-z0-9_]+).*(ON|OFF)\ *\) ]]; then
        local opt="$(anz_norm_name "${BASH_REMATCH[1]}")"
        anz_push_unique ANZ_OPT_DEPS "$opt"
        ANZ_EVIDENCE+=( "opt_dep|$opt|CMakeLists.txt|option|0.60" )
      fi
    done < <(sed -n '1,500p' "$src/CMakeLists.txt" 2>/dev/null)
    anz_push_unique ANZ_TOOL_DEPS "cmake"
    anz_push_unique ANZ_TOOL_DEPS "ninja"
  fi

  # Meson
  if [[ -f "$src/meson.build" ]]; then
    while IFS= read -r lines; do
      if [[ "$lines" =~ dependency\ *\(\ *\'([A-Za-z0-9._+-]+)\' ]]; then
        local dep="$(anz_norm_name "${BASH_REMATCH[1]}")"
        if [[ "$lines" =~ required:\ *false ]]; then
          anz_push_unique ANZ_OPT_DEPS "$dep"
          ANZ_EVIDENCE+=( "opt_dep|$dep|meson.build|dependency(required:false)|0.75" )
        else
          anz_push_unique ANZ_BUILD_DEPS "$dep"
          ANZ_EVIDENCE+=( "build_dep|$dep|meson.build|dependency|0.90" )
        fi
      fi
    done < "$src/meson.build"
    anz_push_unique ANZ_TOOL_DEPS "meson"
    anz_push_unique ANZ_TOOL_DEPS "ninja"
    anz_push_unique ANZ_TOOL_DEPS "pkg-config"
  fi

  # Autotools
  if [[ -f "$src/configure.ac" || -f "$src/configure.in" || -f "$src/Makefile.am" ]]; then
    local f
    for f in "$src/configure.ac" "$src/configure.in" "$src/Makefile.am"; do
      [[ -f "$f" ]] || continue
      while IFS= read -r lines; do
        if [[ "$lines" =~ PKG_CHECK_MODULES\ *\([^\]]*\]\,\ *\[\ *([A-Za-z0-9._+-]+) ]]; then
          local dep="$(anz_norm_name "${BASH_REMATCH[1]}")"
          anz_push_unique ANZ_BUILD_DEPS "$dep"
          anz_push_unique ANZ_TOOL_DEPS "pkg-config"
          ANZ_EVIDENCE+=( "build_dep|$dep|$(basename -- "$f")|PKG_CHECK_MODULES|0.90" )
        fi
        if [[ "$lines" =~ AC_CHECK_LIB\ *\(\ *([A-Za-z0-9_+-]+)\, ]]; then
          local dep="$(anz_norm_name "${BASH_REMATCH[1]}")"
          anz_push_unique ANZ_BUILD_DEPS "$dep"
          ANZ_EVIDENCE+=( "build_dep|$dep|$(basename -- "$f")|AC_CHECK_LIB|0.70" )
        fi
      done < "$f"
    done
    anz_push_unique ANZ_TOOL_DEPS "autoconf"
    anz_push_unique ANZ_TOOL_DEPS "automake"
    anz_push_unique ANZ_TOOL_DEPS "libtool"
  fi

  # Rust / Cargo
  if [[ -f "$src/Cargo.toml" ]]; then
    awk '
      /^\[dependencies\]/ {dep=1; next}
      /^\[build-dependencies\]/ {bdep=1; next}
      /^\[/ {dep=0; bdep=0}
      dep==1 && /^[A-Za-z0-9_.-]+\s*=/ {
        gsub(/#.*/,""); gsub(/[[:space:]]/,"");
        split($0,a,"="); print "RUN|" a[1]
      }
      bdep==1 && /^[A-Za-z0-9_.-]+\s*=/ {
        gsub(/#.*/,""); gsub(/[[:space:]]/,"");
        split($0,a,"="); print "BUILD|" a[1]
      }
    ' "$src/Cargo.toml" | while IFS='|' read -r typ dep; do
      dep="$(anz_norm_name "$dep")"
      if [[ "$typ" == "BUILD" ]]; then
        anz_push_unique ANZ_BUILD_DEPS "$dep"
        anz_push_unique ANZ_TOOL_DEPS "cargo"
        ANZ_EVIDENCE+=( "build_dep|$dep|Cargo.toml|build-dependencies|0.85" )
      else
        anz_push_unique ANZ_RUN_DEPS "$dep"
        anz_push_unique ANZ_TOOL_DEPS "cargo"
        ANZ_EVIDENCE+=( "run_dep|$dep|Cargo.toml|dependencies|0.85" )
      fi
    done
  fi

  # Go
  if [[ -f "$src/go.mod" ]]; then
    grep -E '^\s*require\s*\(' -n "$src/go.mod" >/dev/null 2>&1 && \
      awk '/^require \(/,/\)/{if($1~"^require"||$0~/^\)/)next; gsub(/\/\/.*/,""); if(NF>=1) print $1}' "$src/go.mod" | \
      while read -r dep; do
        dep="$(basename "$dep")"; dep="$(anz_norm_name "$dep")"
        [[ -n "$dep" ]] && { anz_push_unique ANZ_RUN_DEPS "$dep"; ANZ_EVIDENCE+=( "run_dep|$dep|go.mod|require|0.70" ); }
      done
    anz_push_unique ANZ_TOOL_DEPS "go"
  fi

  # Python
  if [[ -f "$src/pyproject.toml" ]]; then
    anz_push_unique ANZ_TOOL_DEPS "python3"
    awk '
      /^\[project\]/ {p=1; next}
      /^\[build-system\]/ {b=1; next}
      /^\[/ {p=0; b=0}
      p==1 && /dependencies/ {flag=1; next}
      flag==1 && /]/ {flag=0}
      flag==1 {gsub(/[",\[\]]/,""); gsub(/#.*/,""); gsub(/[[:space:]]/,""); if(length($0)) print "RUN|" $0}
      b==1 && /requires/ {bflag=1; next}
      bflag==1 && /]/ {bflag=0}
      bflag==1 {gsub(/[",\[\]]/,""); gsub(/#.*/,""); gsub(/[[:space:]]/,""); if(length($0)) print "TOOL|" $0}
    ' "$src/pyproject.toml" | while IFS='|' read -r typ dep; do
      dep="$(anz_norm_name "$dep")"
      case "$typ" in
        RUN)  anz_push_unique ANZ_RUN_DEPS "$dep"; ANZ_EVIDENCE+=( "run_dep|$dep|pyproject.toml|project.dependencies|0.75" );;
        TOOL) anz_push_unique ANZ_TOOL_DEPS "$dep"; ANZ_EVIDENCE+=( "tool_dep|$dep|pyproject.toml|build-system.requires|0.75" );;
      esac
    done
  fi
  [[ -f "$src/requirements.txt" ]] && \
    sed -E 's/#.*//;s/\s+//g;/^$/d;s/[<>=!].*$//' "$src/requirements.txt" | while read -r dep; do
      dep="$(anz_norm_name "$dep")"
      anz_push_unique ANZ_RUN_DEPS "$dep"
      ANZ_EVIDENCE+=( "run_dep|$dep|requirements.txt|pin|0.70" )
    done

  # Node
  if [[ -f "$src/package.json" ]]; then
    anz_push_unique ANZ_TOOL_DEPS "node"
    if anz_has_cmd jq; then
      jq -r '.dependencies // {} | keys[]' "$src/package.json" 2>/dev/null | while read -r dep; do
        dep="$(anz_norm_name "$dep")"
        anz_push_unique ANZ_RUN_DEPS "$dep"
        ANZ_EVIDENCE+=( "run_dep|$dep|package.json|dependencies|0.75" )
      done
      jq -r '.devDependencies // {} | keys[]' "$src/package.json" 2>/dev/null | while read -r dep; do
        dep="$(anz_norm_name "$dep")"
        anz_push_unique ANZ_TOOL_DEPS "$dep"
        ANZ_EVIDENCE+=( "tool_dep|$dep|package.json|devDependencies|0.70" )
      done
    else
      grep -E '"dependencies"| "devDependencies"' -n "$src/package.json" >/dev/null 2>&1 || true
    fi
  fi

  # Java / Gradle / Maven
  [[ -f "$src/pom.xml" ]] && anz_push_unique ANZ_TOOL_DEPS "maven"
  [[ -f "$src/build.gradle" ]] && anz_push_unique ANZ_TOOL_DEPS "gradle"

  # .NET
  if compgen -G "$src/*.csproj" >/dev/null; then
    anz_push_unique ANZ_TOOL_DEPS "dotnet"
    grep -R -n -E '<PackageReference[^>]*Include=' "$src" 2>/dev/null | \
      sed -E 's/.*Include="([^"]+)".*/\1/' | while read -r dep; do
        dep="$(anz_norm_name "$dep")"
        anz_push_unique ANZ_RUN_DEPS "$dep"
        ANZ_EVIDENCE+=( "run_dep|$dep|*.csproj|PackageReference|0.70" )
      done
  fi

  return 0
}
# 06-adm-analyze.part2.sh
# Continuação: análise de código, coleta de tools por build_type,
# merge com metafile, relatório (texto + JSON) e main/CLI.
if [[ -n "${ADM_ANALYZE_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_ANALYZE_LOADED_PART2=1
###############################################################################
# Escaneio de código (heurístico)
###############################################################################
adm_analyze_scan_code() {
  local src="$1"
  [[ -d "$src" ]] || { anz_err "scan_code: SRC_DIR inválido: $src"; return 1; }

  # Includes C/C++ populares
  local pat_inc='(#include[[:space:]]*<([^>]+)>)'
  local files
  files="$(anz_rg_or_grep '#include[[:space:]]*<[^>]+>' "$src" --ext "c,cc,cpp,cxx,h,hpp,hh" --max "$ADM_ANALYZE_MAX_FILES")"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local inc="$(echo "$line" | sed -n 's/.*#include[[:space:]]*<\([^>]\+\)>.*/\1/p')"
    [[ -z "$inc" ]] && continue
    local dep=""
    case "$inc" in
      zlib.h) dep="zlib";;
      png.h) dep="libpng";;
      openssl/*) dep="openssl";;
      curl/curl.h) dep="curl";;
      bzlib.h) dep="bzip2";;
      xz.h|lzma.h) dep="xz";;
      zstd.h) dep="zstd";;
      expat.h) dep="expat";;
      sqlite3.h) dep="sqlite3";;
      pcre2.h|pcre2/*.h) dep="pcre2";;
      pcre.h) dep="pcre";;
      ncurses.h|curses.h) dep="ncurses";;
      readline/readline.h) dep="readline";;
      freetype/*.h) dep="freetype";;
      harfbuzz/*.h) dep="harfbuzz";;
      libxml/*.h|libxml2/*.h) dep="libxml2";;
      gtk/*) dep="gtk";;
      qt*.h) dep="qt5";; # heurística grossa
      *) dep="";;
    esac
    if [[ -n "$dep" ]]; then
      dep="$(anz_norm_name "$dep")"
      anz_push_unique ANZ_BUILD_DEPS "$dep"
      anz_push_unique ANZ_RUN_DEPS "$dep"
      local f="$(echo "$line" | cut -d: -f1)"
      ANZ_EVIDENCE+=( "run_dep|$dep|$f|#include <$inc>|0.70" )
    fi
  done <<< "$files"

  # Flags -l<lib>
  anz_rg_or_grep '(^|[[:space:]])-l[A-Za-z0-9_+-]+' "$src" --ext "c,cc,cpp,cxx,ldflags,txt,sh,make,mak,cmake" --max "$ADM_ANALYZE_MAX_FILES" | \
    sed -E 's/.*(^|[[:space:]])-l([A-Za-z0-9_+-]+).*/\2/' | sort -u | while read -r l; do
      local dep="$(anz_norm_name "$l")"
      anz_push_unique ANZ_BUILD_DEPS "$dep"
      ANZ_EVIDENCE+=( "build_dep|$dep|flags|-l$dep|0.65" )
    done

  # CUDA / OpenCL
  anz_rg_or_grep '<(cuda.h|CL/cl.h)>' "$src" --ext "c,cc,cpp,cxx,h,hpp,hh,cu,cl" --max "$ADM_ANALYZE_MAX_FILES" | while read -r l; do
    if [[ "$l" =~ cuda\.h ]]; then
      anz_push_unique ANZ_OPT_DEPS "cuda"
      ANZ_EVIDENCE+=( "opt_dep|cuda|$(echo "$l"|cut -d: -f1)|#include <cuda.h>|0.80" )
    elif [[ "$l" =~ CL/cl\.h ]]; then
      anz_push_unique ANZ_OPT_DEPS "opencl"
      ANZ_EVIDENCE+=( "opt_dep|opencl|$(echo "$l"|cut -d: -f1)|#include <CL/cl.h>|0.80" )
    fi
  done

  # Python imports
  anz_rg_or_grep '^\s*(from|import)\s+([A-Za-z0-9_]+)' "$src" --ext "py" --max "$ADM_ANALYZE_MAX_FILES" | \
    sed -E 's/.*(from|import)[[:space:]]+([A-Za-z0-9_]+).*/\2/' | sort -u | while read -r m; do
      local dep="$(anz_norm_name "$m")"
      anz_push_unique ANZ_RUN_DEPS "$dep"
      ANZ_EVIDENCE+=( "run_dep|$dep|*.py|import $dep|0.55" )
    done

  # Node requires/imports
  anz_rg_or_grep 'require\(\x27[^'\'']+\x27\)|require\("[^"]+"\)|import[[:space:]]+[^;]*from[[:space:]]+["'\''][^"'\'']+["'\'']' "$src" --ext "js,ts" --max "$ADM_ANALYZE_MAX_FILES" | \
    sed -E "s/.*require\((\"|')([^\"']+)(\"|').*/\2/;s/.*from[[:space:]]+(\"|')([^\"']+)(\"|').*/\2/" | \
    grep -E '^[A-Za-z0-9@/_.-]+$' | cut -d/ -f1 | sort -u | while read -r m; do
      local dep="$(anz_norm_name "$m")"
      anz_push_unique ANZ_RUN_DEPS "$dep"
      ANZ_EVIDENCE+=( "run_dep|$dep|*.{js,ts}|require/import|0.55" )
    done

  return 0
}

###############################################################################
# Coleta de ferramentas por build_type
###############################################################################
adm_analyze_collect_tools() {
  local btype="$1"
  case "$btype" in
    cmake) anz_push_unique ANZ_TOOL_DEPS "cmake"; anz_push_unique ANZ_TOOL_DEPS "ninja"; anz_push_unique ANZ_TOOL_DEPS "pkg-config";;
    meson) anz_push_unique ANZ_TOOL_DEPS "meson"; anz_push_unique ANZ_TOOL_DEPS "ninja"; anz_push_unique ANZ_TOOL_DEPS "pkg-config";;
    autotools) anz_push_unique ANZ_TOOL_DEPS "autoconf"; anz_push_unique ANZ_TOOL_DEPS "automake"; anz_push_unique ANZ_TOOL_DEPS "libtool"; anz_push_unique ANZ_TOOL_DEPS "pkg-config";;
    cargo) anz_push_unique ANZ_TOOL_DEPS "cargo";;
    go) anz_push_unique ANZ_TOOL_DEPS "go";;
    python) anz_push_unique ANZ_TOOL_DEPS "python3";;
    node) anz_push_unique ANZ_TOOL_DEPS "node";;
    java) anz_push_unique ANZ_TOOL_DEPS "maven"; anz_push_unique ANZ_TOOL_DEPS "gradle";;
    .net) anz_push_unique ANZ_TOOL_DEPS "dotnet";;
    make) : ;;
    *) : ;;
  esac
  return 0
}

###############################################################################
# Merge com Metafile (opcional)
###############################################################################
adm_analyze_merge_with_metafile() {
  local metafile="${1:-${ANZ_META[metafile]}}"
  [[ -z "$metafile" ]] && return 0
  [[ -f "$metafile" ]] || { anz_err "metafile ausente: $metafile"; return 2; }
  if ! adm_meta_load "$metafile"; then
    anz_err "falha ao carregar metafile: $metafile"
    return 2
  fi
  local m_build_type; m_build_type="$(adm_meta_get build_type 2>/dev/null || true)"
  [[ -n "$m_build_type" && "$m_build_type" != "${ANZ_RESULT[build_system]}" ]] && \
    anz_warn "build_type do metafile ($m_build_type) difere da análise (${ANZ_RESULT[build_system]})"

  # Merge de listas
  local addlist() {
    local key="$1" arrname="$2"
    local csv; csv="$(adm_meta_get "$key" 2>/dev/null || true)"
    [[ -z "$csv" ]] && return 0
    IFS=',' read -r -a _L <<<"$csv"
    local d; for d in "${_L[@]}"; do
      d="$(anz_norm_name "$(echo "$d" | xargs)")"
      [[ -z "$d" ]] && continue
      anz_push_unique "$arrname" "$d"
    done
  }
  addlist run_deps  ANZ_RUN_DEPS
  addlist build_deps ANZ_BUILD_DEPS
  addlist opt_deps  ANZ_OPT_DEPS
  return 0
}

###############################################################################
# Relatórios (texto e JSON)
###############################################################################
__anz_print_list() {
  local -n ref="$1"
  local sep=""
  for x in "${ref[@]}"; do
    printf "%s%s" "$sep" "$x"; sep=","
  done
}

adm_analyze_emit_report() {
  local json="${1:-false}"

  # Texto
  local evj=""
  local be="$(IFS=','; echo "${ANZ_BUILD_EVIDENCE[*]}")"
  echo "build_system=${ANZ_RESULT[build_system]:-unknown} (confidence=${ANZ_RESULT[build_confidence]:-0.0}) evidence=${be:-"-"}"

  local l
  for l in "${ANZ_LANGS[@]}"; do
    IFS='|' read -r name tc conf files <<<"$l"
    echo "language=${name} toolchain=${tc:-"-"} (confidence=${conf}) files=${files}"
  done

  local s_build s_run s_opt s_tool
  mapfile -t _SB < <(printf "%s\n" "${ANZ_BUILD_DEPS[@]}" | sort -u)
  mapfile -t _SR < <(printf "%s\n" "${ANZ_RUN_DEPS[@]}"   | sort -u)
  mapfile -t _SO < <(printf "%s\n" "${ANZ_OPT_DEPS[@]}"   | sort -u)
  mapfile -t _ST < <(printf "%s\n" "${ANZ_TOOL_DEPS[@]}"  | sort -u)

  printf -v s_build "%s" "$(printf "%s\n" "${_SB[@]}" | paste -sd, -)"
  printf -v s_run   "%s" "$(printf "%s\n" "${_SR[@]}" | paste -sd, -)"
  printf -v s_opt   "%s" "$(printf "%s\n" "${_SO[@]}" | paste -sd, -)"
  printf -v s_tool  "%s" "$(printf "%s\n" "${_ST[@]}" | paste -sd, -)"

  echo "tool_deps: ${s_tool}"
  echo "build_deps: ${s_build}"
  echo "run_deps: ${s_run}"
  echo "opt_deps: ${s_opt}"

  echo "RESOLVER: build=${s_build} | run=${s_run} | opt=${s_opt} | tool=${s_tool}"

  # JSON
  if [[ "$json" == "true" ]]; then
    echo "{"
    echo "  \"schema\":\"adm.analyze.v1\","
    echo "  \"name\":$(printf '%s' "\"${ANZ_META[name]}\"" | sed 's/\\/\\\\/g;s/"/\\"/g'),"
    echo "  \"version\":$(printf '%s' "\"${ANZ_META[version]}\"" | sed 's/\\/\\\\/g;s/"/\\"/g'),"
    echo "  \"category\":$(printf '%s' "\"${ANZ_META[category]}\"" | sed 's/\\/\\\\/g;s/"/\\"/g'),"
    echo "  \"profile\":$(printf '%s' "\"${ANZ_META[profile]:-$ADM_PROFILE_DEFAULT}\"" | sed 's/\\/\\\\/g;s/"/\\"/g'),"
    echo "  \"build_system\":{\"value\":\"${ANZ_RESULT[build_system]}\",\"confidence\":${ANZ_RESULT[build_confidence]},\"evidence\":[\"${be}\"]},"
    echo "  \"languages\": ["
    local first=1
    for l in "${ANZ_LANGS[@]}"; do
      IFS='|' read -r name tc conf files <<<"$l"
      [[ $first -eq 0 ]] && echo ","
      echo -n "    {\"name\":\"$name\",\"toolchain\":["
      IFS='|' read -r -a tca <<<"$tc"
      local i sep=""
      for i in ${tc//|/ }; do echo -n "${sep}\"$i\""; sep=","; done
      echo "],\"confidence\":$conf,\"files\":$files}"
      first=0
    done
    echo "  ],"
    echo "  \"tool_deps\": [$(printf '"%s"' "$(printf '%s\n' "${_ST[@]}" | paste -sd '","' -)")],"
    echo "  \"build_deps\": [$(printf '"%s"' "$(printf '%s\n' "${_SB[@]}" | paste -sd '","' -)")],"
    echo "  \"run_deps\":   [$(printf '"%s"' "$(printf '%s\n' "${_SR[@]}" | paste -sd '","' -)")],"
    echo "  \"opt_deps\":   [$(printf '"%s"' "$(printf '%s\n' "${_SO[@]}" | paste -sd '","' -)")],"
    echo "  \"notes\": [$(printf '"%s"' "$(printf '%s\n' "${ANZ_NOTES[@]}" | paste -sd '","' -)")],"
    echo "  \"evidence\": ["
    first=1
    local e
    for e in "${ANZ_EVIDENCE[@]}"; do
      IFS='|' read -r typ dep file line conf <<<"$e"
      [[ $first -eq 0 ]] && echo ","
      echo -n "    {\"type\":\"$typ\",\"dep\":\"$dep\",\"file\":\"$file\",\"line\":\"$(echo "$line" | sed 's/\\/\\\\/g;s/"/\\"/g')\",\"confidence\":$conf}"
      first=0
    done
    echo ""
    echo "  ]"
    echo "}"
  fi
  return 0
}

###############################################################################
# Main / CLI
###############################################################################
adm_analyze_main() {
  local src="" meta="" json="false" strict="false" max="$ADM_ANALYZE_MAX_FILES"
  ANZ_META[profile]="$ADM_PROFILE_DEFAULT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --metafile) meta="$2"; shift 2;;
      --category) ANZ_META[category]="$2"; shift 2;;
      --name)     ANZ_META[name]="$2"; shift 2;;
      --version)  ANZ_META[version]="$2"; shift 2;;
      --profile)  ANZ_META[profile]="$2"; shift 2;;
      --max-files) max="$2"; shift 2;;
      --json)     json="true"; shift;;
      --strict)   strict="true"; shift;;
      -h|--help)  echo "uso: adm_analyze <SRC_DIR> [--category C] [--name N] [--version V] [--metafile P] [--profile P] [--max-files N] [--json] [--strict]"; return 2;;
      *) if [[ -z "$src" ]]; then src="$1"; shift; else anz_warn "arg desconhecido: $1"; shift; fi;;
    esac
  done

  [[ -n "$src" && -d "$src" ]] || { anz_err "SRC_DIR inválido: $src"; return 1; }
  ANZ_META[metafile]="$meta"

  adm_step "${ANZ_META[name]:-pkg}" "${ANZ_META[version]:-ver}" "Analisando source"
  adm_with_spinner "Detectando build system..." -- adm_analyze_detect_build_system "$src" "$strict" || return $?
  adm_with_spinner "Detectando linguagens..."   -- adm_analyze_detect_languages "$src" || true
  adm_with_spinner "Varredura de manifests..."  -- adm_analyze_scan_manifests "$src" || true
  adm_with_spinner "Varredura de código..."     -- adm_analyze_scan_code "$src" || true
  adm_with_spinner "Coletando toolchains..."    -- adm_analyze_collect_tools "${ANZ_RESULT[build_system]}" || true
  [[ -n "$meta" ]] && adm_with_spinner "Mesclando com metafile..." -- adm_analyze_merge_with_metafile "$meta" || true

  # Checagem de truncamento (performance)
  local tot="$(anz_count_files "$src")"
  if (( tot > max )); then
    anz_warn "análise truncada: $tot arquivos > limite $max; aumente --max-files"
    anz_push_unique ANZ_NOTES "analysis truncated at $max files of $tot"
  fi

  adm_analyze_emit_report "$json"
  adm_ok "análise concluída"
  return 0
}

###############################################################################
# Execução direta (CLI)
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  adm_analyze_main "$@" || exit $?
fi

###############################################################################
# Marcar como carregado
###############################################################################
ADM_ANALYZE_LOADED=1
export ADM_ANALYZE_LOADED
