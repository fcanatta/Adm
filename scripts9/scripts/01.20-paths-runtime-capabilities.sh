#!/usr/bin/env bash
# 01.20-paths-runtime-capabilities.sh
# Paths, checagens de runtime e detecção de capacidades para o ADM.
# Local: /usr/src/adm/scripts/01.20-paths-runtime-capabilities.sh

###############################################################################
# Modo estrito + trap de erros (sem erros silenciosos)
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__adm_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] Falha: codigo=${code} linha=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __adm_err_trap ERR

###############################################################################
# Defaults e caminhos-base
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_CACHE_DIR="${ADM_CACHE_DIR:-${ADM_ROOT}/cache}"
ADM_WORK_DIR="${ADM_WORK_DIR:-${ADM_ROOT}/work}"
ADM_PACKAGES_DIR="${ADM_PACKAGES_DIR:-${ADM_ROOT}/packages}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_ROOT}/db}"
ADM_INSTALLED_DB_DIR="${ADM_INSTALLED_DB_DIR:-${ADM_DB_DIR}/installed}"

# Fallbacks de logging se 01.10 não estiver carregado
adm_is_cmd() { command -v "$1" >/dev/null 2>&1; }
__adm_has_colors() { [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; }
if __adm_has_colors; then
  ADM_COLOR_RST="$(tput sgr0)"; ADM_COLOR_OK="$(tput setaf 2)"; ADM_COLOR_WRN="$(tput setaf 3)"
  ADM_COLOR_ERR="$(tput setaf 1)"; ADM_COLOR_INF="$(tput setaf 6)"; ADM_COLOR_DBG="$(tput setaf 5)"; ADM_COLOR_BLD="$(tput bold)"
else
  ADM_COLOR_RST=""; ADM_COLOR_OK=""; ADM_COLOR_WRN=""; ADM_COLOR_ERR=""; ADM_COLOR_INF=""; ADM_COLOR_DBG=""; ADM_COLOR_BLD=""
fi
adm_info()  { echo -e "${ADM_COLOR_INF}[ADM]${ADM_COLOR_RST} $*"; }
adm_ok()    { echo -e "${ADM_COLOR_OK}[OK ]${ADM_COLOR_RST} $*"; }
adm_warn()  { echo -e "${ADM_COLOR_WRN}[WAR]${ADM_COLOR_RST} $*" 1>&2; }
adm_error() { echo -e "${ADM_COLOR_ERR}[ERR]${ADM_COLOR_RST} $*" 1>&2; }
adm_debug() { echo -e "${ADM_COLOR_DBG}[DBG]${ADM_COLOR_RST} $*"; }

###############################################################################
# Utilitários base
###############################################################################
__adm_ensure_dir() {
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  if [[ ! -d "$d" ]]; then
    if adm_is_cmd install; then
      if [[ $EUID -ne 0 ]] && adm_is_cmd sudo; then
        sudo install -d -m "$mode" -o "$owner" -g "$group" "$d"
      else
        install -d -m "$mode" -o "$owner" -g "$group" "$d"
      fi
    else
      mkdir -p "$d"
      chmod "$mode" "$d"
      chown "$owner:$group" "$d" || true
    fi
  fi
}

adm_require_tools() {
  local miss=() c
  for c in "$@"; do adm_is_cmd "$c" || miss+=("$c"); done
  if ((${#miss[@]})); then
    adm_error "Ferramentas ausentes: ${miss[*]}"
    return 1
  fi
  return 0
}

adm_version_ge() {
  # uso: adm_version_ge "1.2.3" "1.2"
  # compara por sort -V
  local a="${1:?}" b="${2:?}"
  [[ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | tail -n1)" == "$a" ]]
}

adm_bin_which() {
  # imprime caminho absoluto do binário ou vazio
  local b="$1"
  command -v "$b" 2>/dev/null || true
}

###############################################################################
# Inicialização de diretórios e paths
###############################################################################
adm_paths_init() {
  __adm_ensure_dir "$ADM_STATE_DIR"
  __adm_ensure_dir "$ADM_LOG_DIR"
  __adm_ensure_dir "$ADM_TMPDIR"
  __adm_ensure_dir "$ADM_CACHE_DIR"
  __adm_ensure_dir "$ADM_WORK_DIR"
  __adm_ensure_dir "$ADM_PACKAGES_DIR"
  __adm_ensure_dir "$ADM_DB_DIR"
  __adm_ensure_dir "$ADM_INSTALLED_DB_DIR"

  # Verifica escrita
  local d
  for d in "$ADM_TMPDIR" "$ADM_CACHE_DIR" "$ADM_WORK_DIR" "$ADM_PACKAGES_DIR" "$ADM_DB_DIR"; do
    [[ -w "$d" ]] || { adm_error "sem escrita em $d"; exit 20; }
  done

  # Sanitiza PATH básico e acrescenta locais comuns
  local add=(
    /usr/local/sbin /usr/local/bin
    /usr/sbin /usr/bin
    /sbin /bin
  )
  local p newpath=""
  IFS=':' read -r -a p <<< "${PATH:-}"
  # adiciona ausentes preservando ordem
  for a in "${add[@]}"; do
    if [[ ":$PATH:" != *":$a:"* ]]; then
      newpath+="${a}:"
    fi
  done
  PATH="${newpath}${PATH:-/usr/bin:/bin}"
  export PATH

  # MANPATH/INFOPATH/PKG_CONFIG_PATH
  : "${MANPATH:=/usr/share/man:/usr/local/share/man}"
  : "${INFOPATH:=/usr/share/info:/usr/local/share/info}"
  if [[ -d /usr/local/lib/pkgconfig ]]; then
    PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-/usr/local/lib/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig}"
  else
    PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-/usr/lib/pkgconfig:/usr/share/pkgconfig}"
  fi
  export MANPATH INFOPATH PKG_CONFIG_PATH

  adm_ok "Paths inicializados."
}

###############################################################################
# Detecções de plataforma: arquitetura, kernel, libc, triplet
###############################################################################
__adm_detect_arch()      { uname -m 2>/dev/null || echo unknown; }
__adm_detect_kernel_rel(){ uname -r 2>/dev/null || echo unknown; }
__adm_detect_kernel_maj(){ __adm_detect_kernel_rel | awk -F. '{print $1"."$2}' 2>/dev/null || echo 0.0; }

__adm_detect_libc() {
  # tenta detectar glibc vs musl
  if ldd --version 2>&1 | grep -qi 'musl'; then
    echo musl; return
  fi
  if ldd --version 2>&1 | grep -qi 'glibc\|GNU libc'; then
    echo glibc; return
  fi
  # fallback: strings no ld-so
  if command -v strings >/dev/null 2>&1; then
    local so
    for so in /lib*/ld-musl-*.so*; do [[ -e "$so" ]] && { echo musl; return; } done
    for so in /lib*/ld-linux-*.so* /lib*/ld-*.so*; do [[ -e "$so" ]] && { echo glibc; return; } done
  fi
  echo unknown
}

__adm_detect_triplet() {
  local t=""
  if adm_is_cmd gcc; then t=$(gcc -dumpmachine 2>/dev/null || true); fi
  if [[ -z "$t" && adm_is_cmd clang ]]; then t=$(clang -dumpmachine 2>/dev/null || true); fi
  if [[ -z "$t" ]]; then
    local arch="$(__adm_detect_arch)"
    case "$arch" in
      x86_64)  t="x86_64-unknown-linux-gnu" ;;
      aarch64) t="aarch64-unknown-linux-gnu" ;;
      armv7l)  t="armv7l-unknown-linux-gnueabihf" ;;
      riscv64) t="riscv64-unknown-linux-gnu" ;;
      *)       t="${arch}-unknown-linux-gnu" ;;
    esac
  fi
  echo "$t"
}

###############################################################################
# Capabilities de toolchain/buildsystem
###############################################################################
__adm_supports_lto() {
  if adm_is_cmd gcc; then echo | gcc -x c - -o /dev/null -flto >/dev/null 2>&1 && return 0; fi
  if adm_is_cmd clang; then echo | clang -x c - -o /dev/null -flto >/dev/null 2>&1 && return 0; fi
  return 1
}
__adm_has_ld_lld()  { adm_is_cmd ld.lld; }
__adm_has_ld_gold() { adm_is_cmd ld.gold; }

__adm_detect_jobs() {
  local n=1
  if adm_is_cmd nproc; then n=$(nproc 2>/dev/null || echo 1)
  elif [[ -r /proc/cpuinfo ]]; then n=$(grep -c '^processor' /proc/cpuinfo || echo 1)
  fi
  [[ "$n" =~ ^[0-9]+$ ]] && ((n>0)) || n=1
  echo "$n"
}

__adm_detect_ccache() { adm_is_cmd ccache && echo 1 || echo 0; }
__adm_detect_distcc() { adm_is_cmd distcc && echo 1 || echo 0; }

__adm_detect_doc_tools() {
  local have=()
  adm_is_cmd doxygen  && have+=(doxygen)
  adm_is_cmd sphinx-build && have+=(sphinx)
  adm_is_cmd asciidoc && have+=(asciidoc)
  adm_is_cmd help2man && have+=(help2man)
  echo "${have[*]:-}"
}

__adm_detect_vcs_tools() {
  local have=()
  adm_is_cmd git    && have+=(git)
  adm_is_cmd rsync  && have+=(rsync)
  adm_is_cmd curl   && have+=(curl)
  adm_is_cmd wget   && have+=(wget)
  adm_is_cmd tar    && have+=(tar)
  adm_is_cmd unzip  && have+=(unzip)
  adm_is_cmd 7z     && have+=(7z)
  echo "${have[*]:-}"
}

__adm_detect_buildsystems() {
  local have=()
  adm_is_cmd make   && have+=(make)
  adm_is_cmd ninja  && have+=(ninja)
  adm_is_cmd cmake  && have+=(cmake)
  adm_is_cmd meson  && have+=(meson)
  echo "${have[*]:-}"
}

__adm_detect_lang_toolchains() {
  local have=()
  adm_is_cmd gcc    && have+=(gcc)
  adm_is_cmd g++    && have+=(g++)
  adm_is_cmd clang  && have+=(clang)
  adm_is_cmd clang++&& have+=(clang++)
  adm_is_cmd go     && have+=(go)
  adm_is_cmd rustc  && have+=(rustc)
  adm_is_cmd cargo  && have+=(cargo)
  adm_is_cmd python3 && have+=(python3)
  adm_is_cmd pip3    && have+=(pip3)
  echo "${have[*]:-}"
}

__adm_detect_pack_tools() {
  local have=()
  adm_is_cmd strip  && have+=(strip)
  adm_is_cmd objcopy&& have+=(objcopy)
  adm_is_cmd patchelf&& have+=(patchelf)
  adm_is_cmd zstd   && have+=(zstd)
  adm_is_cmd xz     && have+=(xz)
  echo "${have[*]:-}"
}

__adm_detect_sandbox() {
  if adm_is_cmd bwrap; then echo bwrap; return; fi
  if [[ $EUID -eq 0 ]]; then echo chroot; return; fi
  echo none
}

__adm_btf_available() {
  # tenta descobrir se o kernel possui BTF (útil para eBPF, etc.)
  [[ -r /sys/kernel/btf/vmlinux ]] && echo 1 || echo 0
}

###############################################################################
# Export de tool paths (ccache/distcc) e MAKEFLAGS/NINJAJOBS
###############################################################################
adm_export_tool_paths() {
  local jobs="$(__adm_detect_jobs)"
  : "${MAKEFLAGS:=-j${jobs}}"
  export MAKEFLAGS

  if adm_is_cmd ninja; then
    : "${NINJAJOBS:=${jobs}}"
    export NINJAJOBS
  fi

  # ccache/distcc wrappers (opcional: respeita flags)
  local use_ccache="${ADM_USE_CCACHE:-auto}"
  local use_distcc="${ADM_USE_DISTCC:-auto}"
  local has_cc="$(__adm_detect_ccache)"
  local has_dc="$(__adm_detect_distcc)"

  if [[ "$use_ccache" == "auto" && "$has_cc" == "1" ]] || [[ "$use_ccache" == "1" ]]; then
    if adm_is_cmd ccache; then
      export CC="${CC:-gcc}"; export CXX="${CXX:-g++}"
      export CC="ccache ${CC}"; export CXX="ccache ${CXX}"
      adm_info "ccache habilitado para CC/CXX"
    fi
  fi

  if [[ "$use_distcc" == "auto" && "$has_dc" == "1" ]] || [[ "$use_distcc" == "1" ]]; then
    if adm_is_cmd distcc; then
      export CC="${CC:-gcc}"; export CXX="${CXX:-g++}"
      export CC="distcc ${CC}"; export CXX="distcc ${CXX}"
      adm_info "distcc habilitado para CC/CXX"
    fi
  fi
}
###############################################################################
# Scanner de capacidades e relatório
###############################################################################
declare -A ADM_CAPS

adm_capabilities_scan() {
  ADM_CAPS[arch]="$(__adm_detect_arch)"
  ADM_CAPS[kernel_rel]="$(__adm_detect_kernel_rel)"
  ADM_CAPS[kernel_maj]="$(__adm_detect_kernel_maj)"
  ADM_CAPS[libc]="$(__adm_detect_libc)"
  ADM_CAPS[triplet]="$(__adm_detect_triplet)"
  ADM_CAPS[jobs]="$(__adm_detect_jobs)"
  ADM_CAPS[lto]=$(__adm_supports_lto && echo 1 || echo 0)
  ADM_CAPS[ld_lld]="$(__adm_has_ld_lld && echo 1 || echo 0)"
  ADM_CAPS[ld_gold]="$(__adm_has_ld_gold && echo 1 || echo 0)"
  ADM_CAPS[btf]="$(__adm_btf_available)"

  ADM_CAPS[vcs_tools]="$(__adm_detect_vcs_tools)"
  ADM_CAPS[buildsystems]="$(__adm_detect_buildsystems)"
  ADM_CAPS[lang_toolchains]="$(__adm_detect_lang_toolchains)"
  ADM_CAPS[pack_tools]="$(__adm_detect_pack_tools)"
  ADM_CAPS[doc_tools]="$(__adm_detect_doc_tools)"
  ADM_CAPS[sandbox]="$(__adm_detect_sandbox)"

  # versões (quando possível)
  ADM_CAPS[gcc_ver]="$(gcc -dumpfullversion -dumpversion 2>/dev/null || true)"
  ADM_CAPS[clang_ver]="$(clang --version 2>/dev/null | awk 'NR==1{print $3}' || true)"
  ADM_CAPS[go_ver]="$(go version 2>/dev/null | awk '{print $3}' || true)"
  ADM_CAPS[rustc_ver]="$(rustc --version 2>/dev/null | awk '{print $2}' || true)"
  ADM_CAPS[python_ver]="$(python3 --version 2>/dev/null | awk '{print $2}' || true)"
  ADM_CAPS[cmake_ver]="$(cmake --version 2>/dev/null | awk 'NR==1{print $3}' || true)"
  ADM_CAPS[meson_ver]="$(meson --version 2>/dev/null || true)"
  ADM_CAPS[ninja_ver]="$(ninja --version 2>/dev/null || true)"

  adm_export_tool_paths
}

adm_capabilities_report() {
  local kv
  adm_info "${ADM_COLOR_BLD}Relatório de capacidades:${ADM_COLOR_RST}"
  for kv in arch kernel_rel kernel_maj libc triplet jobs lto ld_lld ld_gold btf sandbox; do
    printf '  - %-14s : %s\n' "$kv" "${ADM_CAPS[$kv]:-?}"
  done
  printf '  - %-14s : %s\n' "VCS" "${ADM_CAPS[vcs_tools]:-}"
  printf '  - %-14s : %s\n' "Buildsystems" "${ADM_CAPS[buildsystems]:-}"
  printf '  - %-14s : %s\n' "Lang" "${ADM_CAPS[lang_toolchains]:-}"
  printf '  - %-14s : %s\n' "Pack" "${ADM_CAPS[pack_tools]:-}"
  printf '  - %-14s : %s\n' "Docs" "${ADM_CAPS[doc_tools]:-}"

  # Alertas úteis
  if [[ "${ADM_CAPS[lto]:-0}" != "1" ]]; then
    adm_warn "Toolchain sem LTO; considere instalar plugins LTO (gcc/clang)."
  fi
  if [[ "${ADM_CAPS[ld_lld]:-0}" != "1" && "${ADM_CAPS[ld_gold]:-0}" != "1" ]]; then
    adm_warn "Linker rápido (ld.lld ou ld.gold) não encontrado; links podem ser mais lentos."
  fi
  if [[ "${ADM_CAPS[sandbox]:-none}" == "none" ]]; then
    adm_warn "Sem sandbox disponível (bwrap/chroot); builds menos isolados."
  fi

  if [[ -n "${ADM_CAPS[gcc_ver]}" ]]; then printf '  - gcc     : %s\n' "${ADM_CAPS[gcc_ver]}"; fi
  if [[ -n "${ADM_CAPS[clang_ver]}" ]]; then printf '  - clang   : %s\n' "${ADM_CAPS[clang_ver]}"; fi
  if [[ -n "${ADM_CAPS[go_ver]}" ]]; then printf '  - go      : %s\n' "${ADM_CAPS[go_ver]}"; fi
  if [[ -n "${ADM_CAPS[rustc_ver]}" ]]; then printf '  - rustc   : %s\n' "${ADM_CAPS[rustc_ver]}"; fi
  if [[ -n "${ADM_CAPS[python_ver]}" ]]; then printf '  - python3 : %s\n' "${ADM_CAPS[python_ver]}"; fi
  if [[ -n "${ADM_CAPS[cmake_ver]}" ]]; then printf '  - cmake   : %s\n' "${ADM_CAPS[cmake_ver]}"; fi
  if [[ -n "${ADM_CAPS[meson_ver]}" ]]; then printf '  - meson   : %s\n' "${ADM_CAPS[meson_ver]}"; fi
  if [[ -n "${ADM_CAPS[ninja_ver]}" ]]; then printf '  - ninja   : %s\n' "${ADM_CAPS[ninja_ver]}"; fi
}

###############################################################################
# Sanity checks de ferramentas críticas por estágio (para early-fail)
###############################################################################
adm_require_core_tooling() {
  # Tooling mínimo para pipeline padrão; não fataliza tudo, mas indica faltas
  local core=(tar xz zstd sha256sum)
  local buildsys=(make cmake meson ninja)
  local fetch=(curl wget git rsync unzip 7z)

  local miss=() c
  for c in "${core[@]}";   do adm_is_cmd "$c" || miss+=("$c"); done
  if ((${#miss[@]})); then
    adm_warn "Core ausente(s): ${miss[*]} — algumas etapas falharão."
  fi
  miss=()
  for c in "${buildsys[@]}"; do adm_is_cmd "$c" || miss+=("$c"); done
  if ((${#miss[@]})); then
    adm_warn "Buildsystems ausentes: ${miss[*]} — detector terá limitações."
  fi
  miss=()
  for c in "${fetch[@]}"; do adm_is_cmd "$c" || miss+=("$c"); done
  if ((${#miss[@]})); then
    adm_warn "Ferramentas de fetch ausentes: ${miss[*]} — fontes remotas limitadas."
  fi
}

###############################################################################
# API pública deste módulo
###############################################################################
adm_paths_runtime_init() {
  adm_paths_init
  adm_capabilities_scan
  adm_capabilities_report
  adm_require_core_tooling
  adm_ok "Paths & capabilities prontos."
}

###############################################################################
# Self-test quando executado diretamente
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  adm_paths_runtime_init
fi
