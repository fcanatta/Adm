#!/usr/bin/env bash
# 04.20-source-heuristics-matrix.sh
# Heurísticas completas para idiomas, compiladores, linkers, flags, docs e perfis.
# Local: /usr/src/adm/scripts/04.20-source-heuristics-matrix.sh
###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__shm_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] heuristics-matrix falhou: codigo=${code} linha=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __shm_err_trap ERR

###############################################################################
# Caminhos, logging (fallback) e utilitários
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_DETECT_DIR="${ADM_DETECT_DIR:-${ADM_STATE_DIR}/detect}"
ADM_HEUR_DIR="${ADM_HEUR_DIR:-${ADM_STATE_DIR}/heuristics}"

adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }
__ensure_dir(){
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  if [[ ! -d "$d" ]]; then
    if adm_is_cmd install; then
      if [[ $EUID -ne 0 ]] && adm_is_cmd sudo; then
        sudo install -d -m "$mode" -o "$owner" -g "$group" "$d"
      else
        install -d -m "$mode" -o "$owner" -g "$group" "$d"
      fi
    else
      mkdir -p "$d"; chmod "$mode" "$d"; chown "$owner:$group" "$d" || true
    fi
  fi
}
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_TMPDIR"; __ensure_dir "$ADM_HEUR_DIR"

# Cores simples
if [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
shm_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
shm_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
shm_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
shm_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }

tmpfile(){ mktemp "${ADM_TMPDIR}/shm.XXXXXX"; }

###############################################################################
# Leitura dos artefatos de detecção (detect.json/env) do 04.10
###############################################################################
__shm_json_get_array(){
  # uso: __shm_json_get_array <json_path> <key> -> imprime linhas
  local jf="$1" key="$2"
  if adm_is_cmd jq; then
    jq -r --arg k "$key" '.[$k][]? // empty' "$jf" 2>/dev/null || true
  else
    # fallback bem simples: extrai blocos ["a","b"]
    awk -v k="\"$key\"" '
      $0 ~ k {flag=1}
      flag && /\[/ {gsub(/.*\[/,""); gsub(/\].*/,""); gsub(/"/,""); gsub(/,/,"\n"); print; flag=0}
    ' "$jf" 2>/dev/null | sed '/^$/d' || true
  fi
}

__shm_json_get_object_kv(){
  # uso: __shm_json_get_object_kv <json_path> <obj_key> -> imprime "k=v"
  local jf="$1" key="$2"
  if adm_is_cmd jq; then
    jq -r --arg k "$key" '.[$k] | to_entries[]? | "\(.key)=\(.value)"' "$jf" 2>/dev/null || true
  else
    # fallback tosco: pega linhas "  "k": v,"
    sed -n "/\"$key\"[[:space:]]*:/,/^[}]/p" "$jf" 2>/dev/null \
      | sed -nE 's/^[[:space:]]*"([^"]+)"[[:space:]]*:[[:space:]]*("?)([^",}]+)\2.*/\1=\3/p'
  fi
}

__shm_load_detect(){
  # Define variáveis globais: DET_LANGS[], DET_BUILDSYS[], DET_DOCS[], DET_TOOLCAPS (assoc), DET_KFW[]
  local workdir="${1:?}"
  local cat="${ADM_META[category]:-unknown}" prog="${ADM_META[name]:-unknown}"
  local djson="${ADM_DETECT_DIR}/${cat}/${prog}/detect.json"
  local denv="${ADM_DETECT_DIR}/${cat}/${prog}/detect.env"

  DET_LANGS=(); DET_BUILDSYS=(); DET_DOCS=(); DET_KFW=(); declare -gA DET_TOOLCAPS=()

  if [[ -r "$djson" ]]; then
    mapfile -t DET_LANGS   < <(__shm_json_get_array "$djson" "languages")
    mapfile -t DET_BUILDSYS< <(__shm_json_get_array "$djson" "buildsystems")
    mapfile -t DET_DOCS    < <(__shm_json_get_array "$djson" "docs")
    mapfile -t DET_KFW     < <(__shm_json_get_array "$djson" "kernel_firmware")
    while IFS='=' read -r k v; do [[ -n "$k" ]] && DET_TOOLCAPS["$k"]="$v"; done < <(__shm_json_get_object_kv "$djson" "toolchain_caps")
  else
    # fallback: varredura rápida (quando detect.json não existe)
    shm_warn "detect.json ausente; usando fallback rápido."
    # linguagens por extensões principais
    compgen -G "$workdir/**/*.c" >/dev/null && DET_LANGS+=("C")
    compgen -G "$workdir/**/*.cpp" >/dev/null && DET_LANGS+=("C++")
    [[ -f "$workdir/CMakeLists.txt" ]] && DET_BUILDSYS+=("CMake")
    [[ -f "$workdir/meson.build" ]]    && DET_BUILDSYS+=("Meson")
    [[ -f "$workdir/pyproject.toml" || -f "$workdir/setup.py" ]] && DET_BUILDSYS+=("Python")
    [[ -f "$workdir/Cargo.toml" ]]     && DET_BUILDSYS+=("Cargo")
    [[ -f "$workdir/go.mod" ]]         && DET_BUILDSYS+=("GoModules")
    [[ -f "$workdir/package.json" ]]   && DET_BUILDSYS+=("Node")
  fi
}

###############################################################################
# Heurísticas de seleção de compilador/linker por linguagem
###############################################################################
__pick_cc_for_c(){
  if adm_is_cmd clang; then echo "clang"; elif adm_is_cmd gcc; then echo "gcc"; else echo ""; fi
}
__pick_cxx_for_cpp(){
  if adm_is_cmd clang++; then echo "clang++"; elif adm_is_cmd g++; then echo "g++"; else echo ""; fi
}
__pick_fc_for_fortran(){
  if adm_is_cmd gfortran; then echo "gfortran"; else echo ""; fi
}
__pick_ld(){
  if adm_is_cmd ld.lld; then echo "ld.lld"; elif adm_is_cmd ld.gold; then echo "ld.gold"; else echo "ld"; fi
}

__cpu_native_flag(){
  # retorna -march/-mcpu razoável; evita quebrar em VMs antigas
  local cc="${1:-gcc}"
  case "$cc" in
    *clang*) echo "-march=native" ;;
    *gcc*)   echo "-march=native" ;;
    *) echo "" ;;
  esac
}

__sanitize_flags(){
  # tira flags perigosas duplicadas e garante ordem básica
  sed -E 's/[[:space:]]+/ /g; s/ *$//;'
}

###############################################################################
# Perfis e geração de flags por linguagem/libc/sanitizers/LTO
###############################################################################
__supports_flag(){
  # testa rapidamente se o compilador aceita uma flag (C)
  local cc="${1:?}" flag="${2:?}"
  echo 'int main(){return 0;}' | "$cc" -x c - -o /dev/null "$flag" >/dev/null 2>&1
}

__mk_flags_c_like(){
  # uso: __mk_flags_c_like <cc> <profile> <libc>
  local cc="$1" profile="$2" libc="$3"
  local base="-pipe -fPIC"
  local warn="-Wall -Wextra -Wformat=2 -Werror=format-security"
  local dbg="-g"
  local opt=""
  local arch="$(__cpu_native_flag "$cc")"

  case "$profile" in
    aggressive) opt="-O3 -fno-plt -fno-semantic-interposition";;
    normal)     opt="-O2";;
    minimal)    opt="-O0"; dbg="";;
    *)          opt="-O2";;
  esac

  # LTO se suportado
  local lto=""; if __supports_flag "$cc" "-flto"; then
    [[ "$profile" == "aggressive" || "$profile" == "normal" ]] && lto="-flto"
  fi

  # Fortify & relro & pie (se possível)
  local harden=""
  if [[ "$libc" == "glibc" ]]; then
    harden="-D_FORTIFY_SOURCE=3 -fstack-protector-strong -Wl,-z,relro -Wl,-z,now -fPIE"
  else
    harden="-fstack-protector-strong -Wl,-z,relro -Wl,-z,now -fPIE"
  fi

  # Linker preferido
  local ldflag=""
  local ldsel="$(__pick_ld)"
  [[ "$ldsel" == "ld.lld" ]] && ldflag="-fuse-ld=lld"
  [[ "$ldsel" == "ld.gold" ]] && ldflag="-fuse-ld=gold"

  # Sanitizers (apenas aggressive)
  local san=""
  if [[ "$profile" == "aggressive" ]] && __supports_flag "$cc" "-fsanitize=address"; then
    san="-fsanitize=address -fno-omit-frame-pointer"
  fi

  local cflags="$base $arch $opt $dbg $warn $lto $harden $ldflag $san"
  echo "$cflags" | __sanitize_flags
}

__mk_ldflags_common(){
  local profile="$1" libc="$2"
  local pie="-pie"
  local icf=""
  [[ "$profile" == "aggressive" ]] && icf="-Wl,--icf=safe"
  echo "$pie $icf" | __sanitize_flags
}

__mk_lang_matrix(){
  # uso: __mk_lang_matrix <profile> <libc>
  local profile="$1" libc="$2"

  # C
  local cc="$(__pick_cc_for_c)"; local cflags=""; local ldflags=""
  [[ -n "$cc" ]] && cflags="$(__mk_flags_c_like "$cc" "$profile" "$libc")" && ldflags="$(__mk_ldflags_common "$profile" "$libc")"

  # C++
  local cxx="$(__pick_cxx_for_cpp)"; local cxxflags=""
  [[ -n "$cxx" ]] && cxxflags="$(__mk_flags_c_like "$cxx" "$profile" "$libc")"

  # Fortran
  local fc="$(__pick_fc_for_fortran)"; local fflags=""
  [[ -n "$fc" ]] && fflags="-O${profile/aggressive/3}${profile/normal/2}${profile/minimal/0} -fPIC -pipe"

  # Rust
  local cargo=""; adm_is_cmd cargo && cargo="cargo"
  local rust_profile="$profile"; [[ "$profile" == "aggressive" ]] && rust_profile="release-lto"
  # Go
  local go=""; adm_is_cmd go && go="go"; local goflags=""
  [[ "$profile" == "aggressive" ]] && goflags="-ldflags='-s -w'"

  # Python
  local py=""; adm_is_cmd python3 && py="python3"

  # Zig
  local zig=""; adm_is_cmd zig && zig="zig"; local zigflags=""
  [[ "$profile" == "aggressive" ]] && zigflags="-Drelease-fast=true"

  # D
  local dmd=""; adm_is_cmd dmd && dmd="dmd"; local dflags=""
  [[ -n "$dmd" ]] && dflags="-O -release"

  # Java/Kotlin
  local javac=""; adm_is_cmd javac && javac="javac"
  local gradle=""; adm_is_cmd gradle && gradle="gradle"
  local mvn="";    adm_is_cmd mvn    && mvn="mvn"

  # Node
  local npm=""; adm_is_cmd npm && npm="npm"; local pnpm=""; adm_is_cmd pnpm && pnpm="pnpm"; local yarn=""; adm_is_cmd yarn && yarn="yarn"

  # Swift
  local swiftc=""; adm_is_cmd swiftc && swiftc="swiftc"

  # C#
  local dotnet=""; adm_is_cmd dotnet && dotnet="dotnet"

  # Saída como pares k=v (será serializado mais à frente)
  cat <<EOF
C.cc=${cc}
C.cflags=${cflags}
C.ldflags=${ldflags}
CXX.cxx=${cxx}
CXX.cxxflags=${cxxflags}
CXX.ldflags=${ldflags}
Fortran.fc=${fc}
Fortran.fflags=${fflags}
Rust.cargo=${cargo}
Rust.profile=${rust_profile}
Go.go=${go}
Go.flags=${goflags}
Python.python=${py}
Zig.zig=${zig}
Zig.flags=${zigflags}
D.dmd=${dmd}
D.flags=${dflags}
Java.javac=${javac}
Java.gradle=${gradle}
Java.mvn=${mvn}
Node.npm=${npm}
Node.pnpm=${pnpm}
Node.yarn=${yarn}
Swift.swiftc=${swiftc}
CSharp.dotnet=${dotnet}
EOF
}

###############################################################################
# Heurísticas de comandos por buildsystem
###############################################################################
__mk_buildsystem_cmds(){
  # uso: __mk_buildsystem_cmds <workdir> <profile>
  local root="$1" profile="$2"
  local jobs="${JOBS:-$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)}"
  # Meson > CMake > Autotools > Cargo > Go > Python > Node > Zig > Make
  if [[ -f "$root/meson.build" ]]; then
    echo "meson setup build --buildtype=$([[ $profile == aggressive ]] && echo release || echo debugoptimized) && meson compile -C build -j ${jobs}"
    return
  fi
  if [[ -f "$root/CMakeLists.txt" ]]; then
    local bt="Release"; [[ "$profile" == "minimal" ]] && bt="Debug"
    echo "cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=${bt} && cmake --build build -j ${jobs}"
    return
  fi
  if [[ -x "$root/configure" || -f "$root/configure.ac" ]]; then
    echo "./configure --prefix=/usr && make -j ${jobs}"
    return
  fi
  if [[ -f "$root/Cargo.toml" ]]; then
    [[ "$profile" == "aggressive" ]] && echo "cargo build --release -Zbuild-std=std,panic_abort || cargo build --release" || echo "cargo build"
    return
  fi
  if [[ -f "$root/go.mod" ]]; then
    echo "go build ./..."
    return
  fi
  if [[ -f "$root/pyproject.toml" || -f "$root/setup.py" ]]; then
    echo "python3 -m build"
    return
  fi
  if [[ -f "$root/package.json" ]]; then
    if [[ -f "$root/pnpm-lock.yaml" && -n "$(command -v pnpm || true)" ]]; then
      echo "pnpm i --frozen-lockfile && pnpm run build"
    elif [[ -f "$root/yarn.lock" && -n "$(command -v yarn || true)" ]]; then
      echo "yarn install --frozen-lockfile && yarn build"
    else
      echo "npm ci && npm run build"
    fi
    return
  fi
  if [[ -f "$root/build.zig" ]]; then
    echo "zig build $([[ $profile == aggressive ]] && echo -Drelease-fast=true || echo '')"
    return
  fi
  if compgen -G "$root/Makefile*" >/dev/null; then
    echo "make -j ${jobs}"
    return
  fi
  echo "# Nenhum buildsystem óbvio — verifique README/BUILD."
}

###############################################################################
# Docs heuristics → comandos
###############################################################################
__mk_docs_cmd(){
  local root="$1"
  if [[ -f "$root/Doxyfile" ]]; then echo "doxygen Doxyfile"; return; fi
  if compgen -G "$root/**/conf.py" >/dev/null && grep -RIlq "sphinx" "$root" 2>/dev/null; then
    echo "sphinx-build -b html docs/ _build/html"
    return
  fi
  if [[ -f "$root/mkdocs.yml" ]]; then echo "mkdocs build"; return; fi
  if compgen -G "$root/**/man*/**/*.[1-9]" >/dev/null; then echo "# manpages: disponíveis (instalar com 'install' no prefixo)"; return; fi
  if compgen -G "$root/**/javadoc/**" >/dev/null || grep -RIlq "javadoc" "$root" 2>/dev/null; then
    echo "javadoc -d doc-html $(find src -name '*.java' -print)"
    return
  fi
  echo ""
}
###############################################################################
# Serialização JSON/ENV do matrix
###############################################################################
__json_escape(){ local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; printf '%s' "$s"; }

__emit_matrix_json(){
  # uso: __emit_matrix_json <outfile> <profile> <libc> <root> <build_cmd> <docs_cmd> <langs_kv_stream>
  local out="$1" profile="$2" libc="$3" root="$4" build_cmd="$5" docs_cmd="$6"; shift 6
  local tmp; tmp="$(tmpfile)"

  # Monta objeto "languages": { C:{cc:..., cflags:...}, ... }
  declare -A langmap=() ; while IFS='=' read -r k v; do
    langmap["$k"]="$v"
  done < <(cat)

  {
    echo "{"
    printf '"profile":"%s",' "$( __json_escape "$profile")"
    printf '"libc":"%s",'    "$( __json_escape "$libc")"
    printf '"workdir":"%s",' "$( __json_escape "$root")"
    printf '"build_command":"%s",' "$( __json_escape "$build_cmd")"
    printf '"docs_command":"%s",'  "$( __json_escape "$docs_cmd")"
    echo '"languages":{'
    # Agrupar por prefixo antes do ponto (C., CXX., Rust., ...)
    declare -A keys=()
    for k in "${!langmap[@]}"; do
      pfx="${k%%.*}"
      keys["$pfx"]=1
    done
    # Emissão ordenada básica
    first=1
    for pfx in C CXX Fortran Rust Go Python Zig D Java Node Swift CSharp; do
      [[ -z "${keys[$pfx]:-}" ]] && continue
      ((first==0)) && echo "," || true
      echo -n "\"$pfx\":{"
      # Emite subchaves
      subfirst=1
      for sub in cc cflags ldflags cxx cxxflags fc fflags cargo profile go flags python zig dmd javac gradle mvn npm pnpm yarn swiftc dotnet; do
        key="$pfx.$sub"
        [[ -v langmap["$key"] ]] || continue
        ((subfirst==0)) && echo "," || true
        printf '"%s":"%s"' "$sub" "$( __json_escape "${langmap[$key]}")"
        subfirst=0
      done
      echo -n "}"
      first=0
    done
    echo "}"
    echo "}"
  } > "$tmp"

  if adm_is_cmd jq; then jq . "$tmp" > "$out" 2>/dev/null || cp -f "$tmp" "$out"; else cp -f "$tmp" "$out"; fi
  shm_ok "matrix.json gerado: $out"
}

__emit_matrix_env(){
  # uso: __emit_matrix_env <outfile> <profile> <libc> <build_cmd> <docs_cmd> <langs_kv_stream>
  local out="$1" profile="$2" libc="$3" build_cmd="$4" docs_cmd="$5"; shift 5
  {
    printf 'ADM_PROFILE=%q\n' "$profile"
    printf 'ADM_LIBC=%q\n' "$libc"
    printf 'ADM_BUILD_CMD=%q\n' "$build_cmd"
    printf 'ADM_DOCS_CMD=%q\n' "$docs_cmd"
    while IFS='=' read -r k v; do
      printf 'ADM_LANG_%s=%q\n' "$(echo "$k" | tr '.' '_' | tr '[:lower:]' '[:upper:]')" "$v"
    done
  } > "$out"
  shm_ok "matrix.env gerado: $out"
}

###############################################################################
# API principal
###############################################################################
shm_build_matrix(){
  # uso: shm_build_matrix <workdir> [--profile aggressive|normal|minimal] [--libc glibc|musl] [--out /path.json]
  local root="${1:?}"; shift || true
  local profile="${ADM_PROFILE:-normal}" libc="${ADM_LIBC:-}"
  local out_json="" ; while (($#)); do
    case "$1" in
      --profile) profile="${2:-normal}"; shift 2 ;;
      --libc)    libc="${2:-}"; shift 2 ;;
      --out)     out_json="${2:-}"; shift 2 ;;
      *) shm_err "opção inválida $1"; return 2 ;;
    esac
  done
  [[ -d "$root" ]] || { shm_err "workdir inválido: $root"; return 3; }

  # libc default pela detecção do runtime (via ldd)
  if [[ -z "$libc" ]]; then
    if ldd --version 2>&1 | grep -qi musl; then libc="musl"; else libc="glibc"; fi
  fi
  case "$profile" in aggressive|normal|minimal) : ;; *) shm_warn "profile desconhecido → normal"; profile="normal";; esac
  case "$libc" in glibc|musl) : ;; *) shm_warn "libc desconhecida → glibc"; libc="glibc";; esac

  # Carrega detect.json/env (se houver)
  __shm_load_detect "$root"

  # Gera matriz de flags e seleções
  mapfile -t LANG_KV < <(__mk_lang_matrix "$profile" "$libc")

  # Sugestões de comandos
  local build_cmd; build_cmd="$(__mk_buildsystem_cmds "$root" "$profile")"
  local docs_cmd;  docs_cmd="$(__mk_docs_cmd "$root")"

  # Caminhos de saída
  local cat="${ADM_META[category]:-unknown}" prog="${ADM_META[name]:-unknown}"
  local outdir="${ADM_HEUR_DIR}/${cat}/${prog}"; __ensure_dir "$outdir"
  local json_path="${out_json:-$outdir/matrix.json}"; local env_path="${outdir}/matrix.env"

  # Emite JSON/ENV
  printf '%s\n' "${LANG_KV[@]}" | __emit_matrix_json "$json_path" "$profile" "$libc" "$root" "$build_cmd" "$docs_cmd" /dev/stdin
  printf '%s\n' "${LANG_KV[@]}" | __emit_matrix_env  "$env_path"  "$profile" "$libc" "$build_cmd" "$docs_cmd" /dev/stdin

  shm_info "Resumo:"
  shm_print_summary "$root"
}

shm_print_summary(){
  local root="${1:?}"
  echo "  languages: ${DET_LANGS[*]:-?}"
  echo "  buildsys : ${DET_BUILDSYS[*]:-?}"
  echo "  docs     : ${DET_DOCS[*]:-?}"
  echo "  kernel/fw: ${DET_KFW[*]:-}"
}

shm_guess_commands(){
  local root="${1:?}" profile="${2:-${ADM_PROFILE:-normal}}"
  echo "# Build:"; __mk_buildsystem_cmds "$root" "$profile"
  local dc; dc="$(__mk_docs_cmd "$root")"; [[ -n "$dc" ]] && { echo "# Docs:"; echo "$dc"; }
}

###############################################################################
# Self-test simples (executado diretamente)
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  tdst="$(mktemp -d "${ADM_TMPDIR}/shm-wk.XXXX")"
  mkdir -p "$tdst/proj"; echo 'int main(){return 0;}' > "$tdst/proj/main.c"; echo 'project(p)\nadd_executable(p main.c)' > "$tdst/proj/CMakeLists.txt"
  shm_build_matrix "$tdst/proj" --profile aggressive
  shm_ok "Self-test concluído."
fi
