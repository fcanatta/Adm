#!/usr/bin/env bash
# 04.10-extract-detect.sh
# Extração segura e detecção inteligente de buildsystems, linguagens, deps, docs.
# Local: /usr/src/adm/scripts/04.10-extract-detect.sh
###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__ed_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] extract-detect falhou: codigo=${code} linha=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __ed_err_trap ERR

###############################################################################
# Caminhos, logging (fallback) e utils
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_CACHE_DIR="${ADM_CACHE_DIR:-${ADM_ROOT}/cache}"
ADM_DETECT_DIR="${ADM_DETECT_DIR:-${ADM_STATE_DIR}/detect}"

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
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_TMPDIR"; __ensure_dir "$ADM_DETECT_DIR"

# Cores simples
if [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
ed_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
ed_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
ed_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
ed_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
tmpfile(){ mktemp "${ADM_TMPDIR}/ed.XXXXXX"; }

# Sanitização de path de extração
__ed_validate_member_path() {
  # bloqueia entradas absolutas, com .., ou com prefixos perigosos
  local p="$1"
  [[ -n "$p" ]] || return 1
  [[ "$p" != /* ]] || return 1
  [[ "$p" != *".."* ]] || return 1
  [[ "$p" =~ ^[[:print:]]+$ ]] || return 1
  return 0
}

###############################################################################
# EXTRAÇÃO SEGURA
###############################################################################
__ed_detect_type() {
  local f="$1"
  adm_is_cmd file || { echo "unknown"; return 0; }
  file -b --mime-type -- "$f" 2>/dev/null || echo "unknown"
}

__ed_strip_components() {
  # Remove N componentes de cada caminho (tipo --strip-components do tar)
  local base="$1" n="${2:-0}"
  (( n==0 )) && { printf '%s\n' "$base"; return 0; }
  local IFS='/' parts=()
  read -r -a parts <<< "$base"
  local out=""
  for ((i=n;i<${#parts[@]};i++)); do
    [[ -z "${parts[$i]}" ]] && continue
    out+="${parts[$i]}/"
  done
  out="${out%/}"
  printf '%s\n' "$out"
}

__ed_guess_topdir() {
  # Retorna o diretório top-level se todos os arquivos extraídos compartilham um prefixo
  local root="$1"
  local first=""
  local d
  while IFS= read -r -d '' d; do
    d="${d#"$root"/}"
    IFS='/' read -r first _ <<< "$d"
    break
  done < <(find "$root" -mindepth 1 -maxdepth 2 -print0 | sort -z)
  [[ -z "$first" ]] && { printf '%s\n' "$root"; return 0; }
  # se tudo estiver dentro de $first
  if find "$root" -mindepth 1 -maxdepth 1 -not -name "$first" | grep -q .; then
    printf '%s\n' "$root"
  else
    printf '%s\n' "$root/$first"
  fi
}

__ed_extract_tar_like() {
  local f="$1" dst="$2" strip="${3:-0}"
  local zflag=""
  case "$f" in
    *.tar.gz|*.tgz) zflag="--gzip" ;;
    *.tar.bz2|*.tbz|*.tbz2) zflag="--bzip2" ;;
    *.tar.xz|*.txz) zflag="--xz" ;;
    *.tar.zst|*.tzst) zflag="--zstd" ;;
    *.tar.lz) zflag="--lzip" ;;
    *.tar.lz4) zflag="--lz4" ;;
    *.tar) zflag="" ;;
    *) zflag="" ;; # bsdtar detecta sozinho; GNU tar precisa flags
  esac
  if adm_is_cmd bsdtar; then
    bsdtar -xf "$f" -C "$dst" --no-same-owner --no-same-permissions
  elif adm_is_cmd tar; then
    tar ${zflag} -xf "$f" -C "$dst" --no-same-owner --no-same-permissions
  else
    ed_err "nem tar nem bsdtar disponíveis"
    return 2
  fi
  # valida conteúdo e normaliza
  find "$dst" -xdev -print0 | while IFS= read -r -d '' p; do
    local rel="${p#"$dst"/}"
    __ed_validate_member_path "$rel" || { ed_err "entrada potencialmente insegura: $rel"; return 3; }
  done
  return 0
}

__ed_extract_zip() {
  local f="$1" dst="$2"
  if adm_is_cmd bsdtar; then
    bsdtar -xf "$f" -C "$dst" --no-same-owner --no-same-permissions
  elif adm_is_cmd unzip; then
    unzip -q "$f" -d "$dst"
  else
    ed_err "nem unzip nem bsdtar"
    return 2
  fi
}

__ed_extract_7z() {
  local f="$1" dst="$2"
  if adm_is_cmd 7z; then
    (cd "$dst" && 7z x -y "$f" >/dev/null)
  elif adm_is_cmd bsdtar; then
    bsdtar -xf "$f" -C "$dst"
  else
    ed_err "7z/bsdtar indisponíveis"
    return 2
  fi
}

__ed_extract_single_compressed() {
  # .gz/.xz/.bz2 sem tar dentro; expandir para arquivo e se for tar, extrair
  local f="$1" dst="$2"
  local base="${f##*/}"
  base="${base%.gz}"; base="${base%.xz}"; base="${base%.bz2}"
  local out="$dst/$base"
  case "$1" in
    *.gz)  adm_is_cmd gunzip && cp -f "$f" "$out.gz" && gunzip -f "$out.gz" || { zcat "$f" > "$out"; } ;;
    *.xz)  adm_is_cmd unxz  && cp -f "$f" "$out.xz" && unxz -f "$out.xz"  || { xz -dc "$f" > "$out"; } ;;
    *.bz2) adm_is_cmd bunzip2 && cp -f "$f" "$out.bz2" && bunzip2 -f "$out.bz2" || { bzip2 -dc "$f" > "$out"; } ;;
  esac
  if file -b "$out" | grep -qi 'tar archive'; then
    local subdir; subdir="$(mktemp -d "${dst}/.inner.XXXX")"
    __ed_extract_tar_like "$out" "$subdir"
    rm -f "$out"
    # move conteúdo para dst
    shopt -s dotglob
    mv -f "$subdir"/* "$dst"/
    rmdir "$subdir"
  fi
}

adm_extract() {
  # uso: adm_extract <arquivo|diretorio> <dest_dir> [--strip N]
  local src="${1:?}"; local dst="${2:?}"; shift 2
  local strip=0
  while (($#)); do
    case "$1" in
      --strip) strip="${2:-0}"; shift 2 ;;
      *) ed_err "adm_extract: opção inválida $1"; return 2 ;;
    esac
  done
  __ensure_dir "$dst"

  if [[ -d "$src" ]]; then
    ed_info "Copiando diretório de trabalho..."
    ( shopt -s dotglob; cp -a "$src"/* "$dst"/ || true )
    local top="$(__ed_guess_topdir "$dst")"
    printf '%s\n' "$top"
    return 0
  fi

  [[ -r "$src" ]] || { ed_err "fonte não legível: $src"; return 3; }
  local mime; mime="$(__ed_detect_type "$src")"

  case "$src" in
    *.tar|*.tar.*|*.tgz|*.tbz|*.tbz2|*.txz|*.tzst|*.tlz|*.tlz4)
      __ed_extract_tar_like "$src" "$dst" "$strip"
      ;;
    *.zip) __ed_extract_zip "$src" "$dst" ;;
    *.7z)  __ed_extract_7z "$src" "$dst" ;;
    *.gz|*.xz|*.bz2) __ed_extract_single_compressed "$src" "$dst" ;;
    *.cpio|*.cpio.*)
      if adm_is_cmd bsdtar; then bsdtar -xf "$src" -C "$dst"; else ed_err "cpio requer bsdtar"; return 2; fi
      ;;
    *.deb)
      # extração rápida de deb (ar+tar)
      if adm_is_cmd ar; then
        ( cd "$dst"; ar x "$src"; for t in data.tar.*; do [[ -e "$t" ]] && __ed_extract_tar_like "$t" "$dst"; done )
      else
        ed_err "ar indisponível p/ .deb"
        return 2
      fi
      ;;
    *)
      # Tentar com bsdtar genérico
      if adm_is_cmd bsdtar && bsdtar -tf "$src" >/dev/null 2>&1; then
        bsdtar -xf "$src" -C "$dst"
      else
        ed_err "formato não reconhecido: $src (mime=$mime)"
        return 4
      fi
      ;;
  esac

  # Normaliza permissões básicas
  find "$dst" -type d -print0 | xargs -0 chmod 0755 || true
  find "$dst" -type f -perm -111 -print0 | xargs -0 chmod a+rx || true

  local topdir; topdir="$(__ed_guess_topdir "$dst")"
  ed_ok "Extraído em: $topdir"
  printf '%s\n' "$topdir"
}
###############################################################################
# DETECÇÃO: Linguagens, Buildsystems, Docs, Kernel/Firmware
###############################################################################
__ed_has_any() { local p="$1"; shift; local f; for f in "$@"; do [[ -e "$p/$f" ]] && return 0; done; return 1; }
__ed_glob_any() { local p="$1" g; shift; for g in "$@"; do compgen -G "$p/$g" >/dev/null && return 0; done; return 1; }

detect_languages() {
  local root="${1:?}"
  local -a langs=()
  __ed_glob_any "$root" '**/*.c' '**/*.h' && langs+=(C)
  __ed_glob_any "$root" '**/*.cc' '**/*.cpp' '**/*.cxx' && langs+=(C++)
  __ed_glob_any "$root" '**/*.m' '**/*.mm' && langs+=(ObjC)
  __ed_glob_any "$root" '**/*.f' '**/*.f90' '**/*.F90' && langs+=(Fortran)
  __ed_glob_any "$root" '**/*.rs' && langs+=(Rust)
  __ed_glob_any "$root" '**/*.go' && langs+=(Go)
  __ed_glob_any "$root" '**/*.java' && langs+=(Java)
  __ed_glob_any "$root" '**/*.kt' '**/*.kts' && langs+=(Kotlin)
  __ed_glob_any "$root" '**/*.swift' && langs+=(Swift)
  __ed_glob_any "$root" '**/*.cs' && langs+=(CSharp)
  __ed_glob_any "$root" '**/*.d' && langs+=(D)
  __ed_glob_any "$root" '**/*.hs' && langs+=(Haskell)
  __ed_glob_any "$root" '**/*.ml' '**/*.mli' && langs+=(OCaml)
  __ed_glob_any "$root" '**/*.erl' '**/*.ex' '**/*.exs' && langs+=(Erlang Elixir)
  __ed_glob_any "$root" '**/*.ts' '**/*.tsx' && langs+=(TypeScript)
  __ed_glob_any "$root" '**/*.js' && langs+=(JavaScript)
  __ed_glob_any "$root" '**/*.py' && langs+=(Python)
  __ed_glob_any "$root" '**/*.rb' && langs+=(Ruby)
  __ed_glob_any "$root" '**/*.pl' '**/*.pm' && langs+=(Perl)
  __ed_glob_any "$root" '**/*.lua' && langs+=(Lua)
  __ed_glob_any "$root" '**/*.sh' && langs+=(Shell)
  __ed_glob_any "$root" '**/*.r' '**/*.R' && langs+=(R)
  __ed_glob_any "$root" '**/*.jl' && langs+=(Julia)
  __ed_glob_any "$root" '**/*.php' && langs+=(PHP)
  printf '%s\n' "${langs[@]}" | awk '!seen[$0]++'
}

detect_buildsystems() {
  local root="${1:?}"
  local -a bs=()
  __ed_has_any "$root" configure configure.ac configure.in && bs+=(Autotools)
  __ed_has_any "$root" CMakeLists.txt && bs+=(CMake)
  __ed_has_any "$root" meson.build && bs+=(Meson)
  __ed_has_any "$root" Makefile GNUmakefile makefile && bs+=(Make)
  __ed_has_any "$root" build.ninja && bs+=(Ninja)
  __ed_has_any "$root" SConstruct && bs+=(SCons)
  __ed_has_any "$root" WORKSPACE BUILD && bs+=(Bazel)
  __ed_has_any "$root" BUCK && bs+=(Buck)
  __ed_glob_any "$root" '**/*.pro' && bs+=(QMake)
  __ed_has_any "$root" premake5.lua && bs+=(Premake)
  __ed_has_any "$root" waf && bs+=(Waf)
  __ed_has_any "$root" build.zig && bs+=(Zig)
  __ed_has_any "$root" dub.json dub.sdl && bs+=(Dub)
  __ed_glob_any "$root" '**/*.cabal' && bs+=(Cabal)
  __ed_has_any "$root" stack.yaml && bs+=(Stack)
  __ed_has_any "$root" go.mod && bs+=(GoModules)
  __ed_has_any "$root" Cargo.toml && bs+=(Cargo)
  __ed_has_any "$root" pyproject.toml setup.py setup.cfg requirements.txt && bs+=(Python)
  __ed_has_any "$root" package.json && bs+=(Node)
  __ed_has_any "$root" pom.xml && bs+=(Maven)
  __ed_has_any "$root" build.gradle build.gradle.kts && bs+=(Gradle)
  __ed_has_any "$root" build.xml && bs+=(Ant)
  __ed_has_any "$root" Package.swift && bs+=(SwiftPM)
  __ed_glob_any "$root" '**/*.rockspec' && bs+=(LuaRocks)
  __ed_has_any "$root" Makefile.PL Build.PL && bs+=(PerlMake/MB)
  __ed_glob_any "$root" '**/dune' '**/*.opam' && bs+=(Dune/Opam)
  printf '%s\n' "${bs[@]}" | awk '!seen[$0]++'
}

detect_docs() {
  local root="${1:?}"
  local -a docs=()
  __ed_has_any "$root" Doxyfile && docs+=(Doxygen)
  __ed_has_any "$root" mkdocs.yml && docs+=(MkDocs)
  __ed_glob_any "$root" '**/conf.py' && grep -RIlq "sphinx" "$root" 2>/dev/null && docs+=(Sphinx)
  __ed_glob_any "$root" '**/*.adoc' '**/*.asciidoc' && docs+=(Asciidoctor)
  __ed_glob_any "$root" '**/man*/**/*.[1-9]' && docs+=(ManPages)
  __ed_glob_any "$root" '**/javadoc/**' && docs+=(Javadoc)
  printf '%s\n' "${docs[@]}" | awk '!seen[$0]++'
}

detect_kernel_firmware() {
  local root="${1:?}"
  local tags=()
  if __ed_has_any "$root" Kbuild Kconfig scripts/kconfig/Makefile; then
    tags+=(LinuxKernel)
  fi
  if __ed_has_any "$root" Makefile && grep -RIlq "^ARCH[[:space:]]*=" "$root"/Makefile 2>/dev/null; then
    tags+=(KernelLike)
  fi
  if __ed_has_any "$root" u-boot.mk include/configs && grep -RIlq "U-Boot" "$root" 2>/dev/null; then
    tags+=(UBoot)
  fi
  if __ed_has_any "$root" firmware/ && tags+=(Firmware); then :; fi
  printf '%s\n' "${tags[@]}" | awk '!seen[$0]++'
}

###############################################################################
# DETECÇÃO: Compiladores/Linkers & Capacidades
###############################################################################
detect_toolchain_caps() {
  local -A caps=()
  caps[gcc]=$(adm_is_cmd gcc && echo 1 || echo 0)
  caps[clang]=$(adm_is_cmd clang && echo 1 || echo 0)
  caps[g++]=$(adm_is_cmd g++ && echo 1 || echo 0)
  caps[clang++]=$(adm_is_cmd clang++ && echo 1 || echo 0)
  caps[fortran]=$(adm_is_cmd gfortran && echo 1 || echo 0)
  caps[ld_lld]=$(adm_is_cmd ld.lld && echo 1 || echo 0)
  caps[ld_gold]=$(adm_is_cmd ld.gold && echo 1 || echo 0)
  caps[ar]=$(adm_is_cmd ar && echo 1 || echo 0)
  caps[ranlib]=$(adm_is_cmd ranlib && echo 1 || echo 0)
  caps[strip]=$(adm_is_cmd strip && echo 1 || echo 0)
  caps[make]=$(adm_is_cmd make && echo 1 || echo 0)
  caps[ninja]=$(adm_is_cmd ninja && echo 1 || echo 0)
  caps[cmake]=$(adm_is_cmd cmake && echo 1 || echo 0)
  caps[meson]=$(adm_is_cmd meson && echo 1 || echo 0)
  caps[pkgconf]=$(adm_is_cmd pkgconf && echo 1 || echo 0)
  caps[pkg_config]=$(adm_is_cmd pkg-config && echo 1 || echo 0)
  caps[rustc]=$(adm_is_cmd rustc && echo 1 || echo 0)
  caps[cargo]=$(adm_is_cmd cargo && echo 1 || echo 0)
  caps[go]=$(adm_is_cmd go && echo 1 || echo 0)
  caps[python]=$(adm_is_cmd python3 && echo 1 || echo 0)
  caps[pip]=$(adm_is_cmd pip3 && echo 1 || echo 0)
  caps[node]=$(adm_is_cmd node && echo 1 || echo 0)
  caps[npm]=$(adm_is_cmd npm && echo 1 || echo 0)
  caps[gradle]=$(adm_is_cmd gradle && echo 1 || echo 0)
  caps[mvn]=$(adm_is_cmd mvn && echo 1 || echo 0)
  caps[javac]=$(adm_is_cmd javac && echo 1 || echo 0)
  caps[swiftc]=$(adm_is_cmd swiftc && echo 1 || echo 0)
  caps[zig]=$(adm_is_cmd zig && echo 1 || echo 0)
  caps[dmd]=$(adm_is_cmd dmd && echo 1 || echo 0)
  caps[ld_bfd]=$(adm_is_cmd ld && echo 1 || echo 0)

  # LTO quick check
  local lto=0
  if adm_is_cmd gcc && echo | gcc -x c - -o /dev/null -flto >/dev/null 2>&1; then lto=1
  elif adm_is_cmd clang && echo | clang -x c - -o /dev/null -flto >/dev/null 2>&1; then lto=1
  fi
  caps[lto]=$lto

  # OpenMP quick check
  local omp=0
  if adm_is_cmd gcc && echo 'int main(){return 0;}' | gcc -x c - -fopenmp -o /dev/null >/dev/null 2>&1; then omp=1; fi
  caps[openmp]=$omp

  # Sanitizers quick check (asan)
  local asan=0
  if (adm_is_cmd gcc && echo 'int main(){return 0;}' | gcc -x c - -fsanitize=address -o /dev/null >/dev/null 2>&1) \
     || (adm_is_cmd clang && echo 'int main(){return 0;}' | clang -x c - -fsanitize=address -o /dev/null >/dev/null 2>&1); then
    asan=1
  fi
  caps[asan]=$asan

  # Emite como "k=v" por linha (para consumo simples)
  local k; for k in "${!caps[@]}"; do printf '%s=%s\n' "$k" "${caps[$k]}"; done | sort
}

###############################################################################
# DETECÇÃO: Dependências (heurísticas)
###############################################################################
# Helpers de parse bem leves (sem jq obrigatório)
__ed_kv_print(){ local k="$1" v="$2"; printf '%s=%s\n' "$k" "$v"; }

dep_detect_pkgconfig() {
  local root="${1:?}"
  grep -RIl --include='*.pc' '^Requires' "$root" 2>/dev/null \
    | xargs -r awk -F: '/^Requires/ {print $2}' \
    | sed 's/[(),]//g' | tr ' ' '\n' | sed '/^$/d' | sort -u
}

dep_detect_cmake() {
  local root="${1:?}"
  grep -RIl --include='CMakeLists.txt' --include='*.cmake' -E 'find_package\(|pkg_check_modules\(' "$root" 2>/dev/null \
    | xargs -r sed -nE 's/.*find_package\(([[:space:]]*([A-Za-z0-9_+-]+)).*/\2/ip; s/.*pkg_check_modules\(([[:space:]]*([A-Za-z0-9_+-]+)).*/\2/ip' \
    | sed 's/[[:space:]]//g' | sed '/^$/d' | sort -u
}

dep_detect_meson() {
  local root="${1:?}"
  grep -RIl --include='meson.build' -E 'dependency\(|find_program\(' "$root" 2>/dev/null \
    | xargs -r sed -nE 's/.*dependency\([[:space:]]*'\''([^'\'']+)'\''.*\).*/\1/p' \
    | sort -u
}

dep_detect_autotools() {
  local root="${1:?}"
  grep -RIl --include='configure.ac' --include='configure.in' -E 'PKG_CHECK_MODULES|AC_CHECK_LIB' "$root" 2>/dev/null \
    | while read -r f; do
        sed -nE "s/.*PKG_CHECK_MODULES\(\[[^]]*\],\[[[:space:]]*([^]]+)\].*/\1/p; s/.*AC_CHECK_LIB\(\[([^]]+)\].*/\1/p" "$f"
      done | tr ' ' '\n' | tr ',' '\n' | sed '/^$/d' | sort -u
}

dep_detect_python() {
  local root="${1:?}"
  local out=()
  # pyproject (PEP621)
  if [[ -f "$root/pyproject.toml" ]]; then
    # extração tosca das deps do campo [project] dependencies / [tool.poetry]
    awk '/^\[project\]/{flag=1} /^\[/{if(flag&&$0!~"\\[project\\]")flag=0} flag&&/dependencies[[:space:]]*=/{print}' "$root/pyproject.toml" 2>/dev/null \
      | sed -nE 's/.*\[(.*)\].*/\1/p' >/dev/null || true
    grep -E '^[[:space:]]*[^#].*=' "$root/pyproject.toml" >/dev/null || true
  fi
  [[ -f "$root/requirements.txt" ]] && awk -F'[<>= ]' '{print $1}' "$root/requirements.txt" | sed '/^#/d;/^$/d' || true
}

dep_detect_node() {
  local root="${1:?}"
  [[ -f "$root/package.json" ]] || return 0
  # sem jq: pega blocos "dependencies" e "devDependencies" superficialmente
  awk '/"dependencies"[[:space:]]*:/,/\}/ {print} /"devDependencies"[[:space:]]*:/,/\}/ {print}' "$root/package.json" \
    | sed -nE 's/^[[:space:]]*"([A-Za-z0-9@/_.-]+)":[[:space:]]*".*".*/\1/p' | sort -u
}

dep_detect_cargo() {
  local root="${1:?}"
  [[ -f "$root/Cargo.toml" ]] || return 0
  sed -nE 's/^[[:space:]]*([A-Za-z0-9_+-]+)[[:space:]]*=.*/\1/p' "$root/Cargo.toml" \
    | sed '/^\[/{d}' | sed '/^package$/d' | sed '/^workspace$/d' | sort -u
}

dep_detect_go() {
  local root="${1:?}"
  [[ -f "$root/go.mod" ]] || return 0
  awk '/^require /{print $2} /^require \(/,/^\)/ {print $1}' "$root/go.mod" | sed '/^require$/d;/^\)$/d;/^$/d' | awk '{print $1}' | sort -u
}

dep_detect_java() {
  local root="${1:?}"
  local out=()
  if [[ -f "$root/pom.xml" ]]; then
    sed -nE 's/.*<artifactId>([^<]+)<\/artifactId>.*/\1/p' "$root/pom.xml" | sort -u
  fi
  if compgen -G "$root/build.gradle*" >/dev/null; then
    sed -nE "s/.*implementation[[:space:]]+'([^']+)'.*/\1/p; s/.*api[[:space:]]+'([^']+)'.*/\1/p" "$root"/build.gradle* 2>/dev/null | sort -u
  fi
}

dep_detect_misc() {
  local root="${1:?}"
  # genérico: pkg-config em Makefiles/Meson/CMake
  grep -RIl --include='*Makefile*' -E 'pkg-config|PKG_CONFIG' "$root" 2>/dev/null | xargs -r grep -hEo '[A-Za-z0-9._+-]+(?=\.pc)' | sort -u
}

collect_dependencies() {
  local root="${1:?}"
  {
    dep_detect_pkgconfig "$root"
    dep_detect_cmake "$root"
    dep_detect_meson "$root"
    dep_detect_autotools "$root"
    dep_detect_node "$root"
    dep_detect_cargo "$root"
    dep_detect_go "$root"
    dep_detect_java "$root"
    dep_detect_misc "$root"
  } 2>/dev/null | sed '/^$/d' | sort -u
}
###############################################################################
# EMISSÃO: JSON e ENV
###############################################################################
__ed_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

emit_json_detect() {
  # uso: emit_json_detect <workdir> <outfile.json>
  local root="${1:?}" out="${2:?}"

  mapfile -t langs < <(detect_languages "$root")
  mapfile -t bsys  < <(detect_buildsystems "$root")
  mapfile -t docs  < <(detect_docs "$root")
  mapfile -t kfw   < <(detect_kernel_firmware "$root")
  mapfile -t caps  < <(detect_toolchain_caps)

  local tmp; tmp="$(tmpfile)"
  {
    echo '{'
    printf '"workdir":"%s",' "$(__ed_json_escape "$root")"
    printf '\n"languages":['
    local i
    for ((i=0;i<${#langs[@]};i++)); do
      printf '"%s"%s' "$(__ed_json_escape "${langs[$i]}")" $([[ $i -lt $((${#langs[@]}-1)) ]] && echo "," || echo "")
    done
    printf '],\n"buildsystems":['
    for ((i=0;i<${#bsys[@]};i++)); do
      printf '"%s"%s' "$(__ed_json_escape "${bsys[$i]}")" $([[ $i -lt $((${#bsys[@]}-1)) ]] && echo "," || echo "")
    done
    printf '],\n"docs":['
    for ((i=0;i<${#docs[@]};i++)); do
      printf '"%s"%s' "$(__ed_json_escape "${docs[$i]}")" $([[ $i -lt $((${#docs[@]}-1)) ]] && echo "," || echo "")
    done
    printf '],\n"kernel_firmware":['
    for ((i=0;i<${#kfw[@]};i++)); do
      printf '"%s"%s' "$(__ed_json_escape "${kfw[$i]}")" $([[ $i -lt $((${#kfw[@]}-1)) ]] && echo "," || echo "")
    done
    printf '],\n"toolchain_caps":{'
    for ((i=0;i<${#caps[@]};i++)); do
      local k="${caps[$i]%%=*}" v="${caps[$i]#*=}"
      printf '"%s":%s' "$(__ed_json_escape "$k")" "$v"
      [[ $i -lt $((${#caps[@]}-1)) ]] && printf ','
    done
    printf '}'

    # deps (podem ser muitas; coletar por último)
    mapfile -t deps < <(collect_dependencies "$root")
    printf ',\n"dependencies":['
    for ((i=0;i<${#deps[@]};i++)); do
      printf '"%s"%s' "$(__ed_json_escape "${deps[$i]}")" $([[ $i -lt $((${#deps[@]}-1)) ]] && echo "," || echo "")
    done
    printf ']'

    echo -e '\n}'
  } > "$tmp"

  if adm_is_cmd jq; then
    jq . "$tmp" > "$out" 2>/dev/null || cp -f "$tmp" "$out"
  else
    cp -f "$tmp" "$out"
  fi
  ed_ok "detect.json gerado: $out"
}

emit_env_detect() {
  # uso: emit_env_detect <workdir> <outfile.env>
  local root="${1:?}" out="${2:?}"
  mapfile -t langs < <(detect_languages "$root")
  mapfile -t bsys  < <(detect_buildsystems "$root")
  mapfile -t docs  < <(detect_docs "$root")
  mapfile -t kfw   < <(detect_kernel_firmware "$root")

  {
    printf 'ADM_DETECT_WORKDIR=%q\n' "$root"
    printf 'ADM_DETECT_LANGS=%q\n' "$(printf '%s ' "${langs[@]}" | sed 's/[ ]$//')"
    printf 'ADM_DETECT_BUILDSYS=%q\n' "$(printf '%s ' "${bsys[@]}" | sed 's/[ ]$//')"
    printf 'ADM_DETECT_DOCS=%q\n' "$(printf '%s ' "${docs[@]}" | sed 's/[ ]$//')"
    printf 'ADM_DETECT_KERNEL_FIRMWARE=%q\n' "$(printf '%s ' "${kfw[@]}" | sed 's/[ ]$//')"
  } > "$out"
  ed_ok "detect.env gerado: $out"
}

###############################################################################
# Sugestão de *build command* (heurística)
###############################################################################
adm_guess_build_cmd() {
  local root="${1:?}"
  # ordem de preferência: Meson, CMake, Autotools, Cargo, Go, Python, Node, Zig, Makefile
  if __ed_has_any "$root" meson.build; then
    echo "meson setup build && meson compile -C build"
    return 0
  fi
  if __ed_has_any "$root" CMakeLists.txt; then
    echo "cmake -S . -B build -G Ninja && cmake --build build"
    return 0
  fi
  if __ed_has_any "$root" configure configure.ac; then
    echo "./configure --prefix=/usr && make -j\${JOBS:-$(nproc 2>/dev/null || echo 2)}"
    return 0
  fi
  if __ed_has_any "$root" Cargo.toml; then
    echo "cargo build --release"
    return 0
  fi
  if __ed_has_any "$root" go.mod; then
    echo "go build ./..."
    return 0
  fi
  if __ed_has_any "$root" pyproject.toml setup.py; then
    echo "python3 -m build  # ou: pip wheel ."
    return 0
  fi
  if __ed_has_any "$root" package.json; then
    echo "npm ci && npm run build"
    return 0
  fi
  if __ed_has_any "$root" build.zig; then
    echo "zig build -Drelease=true"
    return 0
  fi
  if __ed_has_any "$root" Makefile GNUmakefile makefile; then
    echo "make -j\${JOBS:-$(nproc 2>/dev/null || echo 2)}"
    return 0
  fi
  echo "# Nenhum buildsystem óbvio; verifique README/BUILD."
}

###############################################################################
# ORQUESTRAÇÃO PRINCIPAL
###############################################################################
adm_detect_all() {
  # uso: adm_detect_all <workdir> [--out /path/detect.json]
  local root="${1:?}" out_json=""
  shift || true
  while (($#)); do
    case "$1" in
      --out) out_json="${2:-}"; shift 2 ;;
      *) ed_err "adm_detect_all: opção inválida $1"; return 2 ;;
    esac
  done
  [[ -d "$root" ]] || { ed_err "workdir não é diretório: $root"; return 3; }

  # onde salvar
  local cat="${ADM_META[category]:-unknown}" prog="${ADM_META[name]:-unknown}"
  local outdir="${ADM_DETECT_DIR}/${cat}/${prog}"; __ensure_dir "$outdir"
  local json_path="${out_json:-$outdir/detect.json}"
  local env_path="${outdir}/detect.env"

  emit_json_detect "$root" "$json_path"
  emit_env_detect  "$root" "$env_path"

  ed_info "Sugestão de build: $(adm_guess_build_cmd "$root")"
}

###############################################################################
# Self-test (executado diretamente)
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # Self-test mínimo: extrai esta pasta (ou um arquivo simple) e roda detect
  tdst="$(mktemp -d "${ADM_TMPDIR}/ed-wk.XXXX")"
  # Se passado um argumento, tente extrair/detectar
  if [[ $# -ge 1 ]]; then
    wk="$(adm_extract "$1" "$tdst")"
  else
    # cria arvorezinha fake
    mkdir -p "$tdst/proj/src" "$tdst/proj/docs"
    printf 'int main(){return 0;}\n' > "$tdst/proj/src/main.c"
    printf 'project(proj)\n' > "$tdst/proj/CMakeLists.txt"
    wk="$tdst/proj"
  fi
  adm_detect_all "$wk"
  ed_ok "Self-test concluído."
fi
