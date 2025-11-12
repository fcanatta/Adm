#!/usr/bin/env bash
# 00.10-env-colors-profiles.sh
# Inicialização de ambiente, detecção de cores e gestão de perfis de build.
# Projeto: ADM (Arquiteto/Administrador de Fontes)
# Local:   /usr/src/adm/scripts/00.10-env-colors-profiles.sh

###############################################################################
# Modo estrito + tratamento de erros
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

# Rastreia a linha/func de erro
__adm_err_trap() {
  local exit_code=$?
  local line=${BASH_LINENO[0]:-?}
  local func=${FUNCNAME[1]:-MAIN}
  echo -e "${ADM_COLOR_ERR}[ADM:ERRO]${ADM_COLOR_RST} Código=${exit_code} Linha=${line} Função=${func}" 1>&2 || true
  exit "${exit_code}"
}
trap __adm_err_trap ERR

# Checa versão mínima do bash
__adm_require_bash() {
  local min_major=4 min_minor=2
  local bmajor=${BASH_VERSINFO[0]:-0}
  local bminor=${BASH_VERSINFO[1]:-0}
  if (( bmajor < min_major || (bmajor == min_major && bminor < min_minor) )); then
    echo "Bash >= ${min_major}.${min_minor} requerido; encontrado ${bmajor}.${bminor}" 1>&2
    exit 2
  fi
}
__adm_require_bash

###############################################################################
# Constantes e caminhos
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_SCRIPTS_DIR="${ADM_SCRIPTS_DIR:-${ADM_ROOT}/scripts}"
ADM_PROFILES_DIR="${ADM_PROFILES_DIR:-${ADM_ROOT}/profiles}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"

# Garantir diretórios base (sem silêncio)
__adm_ensure_dir() {
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  if [[ ! -d "$d" ]]; then
    if command -v install >/dev/null 2>&1; then
      if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
          sudo install -d -m "$mode" -o "$owner" -g "$group" "$d"
        else
          echo "Permissão negada para criar $d; rode como root ou com sudo." 1>&2
          exit 3
        fi
      else
        install -d -m "$mode" -o "$owner" -g "$group" "$d"
      fi
    else
      # fallback: mkdir + chown + chmod (sem calar erros)
      mkdir -p "$d"
      chmod "$mode" "$d"
      chown "$owner:$group" "$d" || true
    fi
  fi
}

__adm_ensure_dir "$ADM_ROOT"
__adm_ensure_dir "$ADM_SCRIPTS_DIR"
__adm_ensure_dir "$ADM_TMPDIR"
__adm_ensure_dir "$ADM_STATE_DIR"

###############################################################################
# Cores/estilos (com fallback seguro)
###############################################################################
__adm_setup_colors() {
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    local ncolors
    ncolors=$(tput colors || echo 0)
    if [[ "$ncolors" -ge 8 ]]; then
      ADM_COLOR_RST="$(tput sgr0)"
      ADM_COLOR_BLD="$(tput bold)"
      ADM_COLOR_DIM="$(tput dim 2>/dev/null || echo)"
      ADM_COLOR_OK="$(tput setaf 2)"     # green
      ADM_COLOR_WRN="$(tput setaf 3)"    # yellow
      ADM_COLOR_ERR="$(tput setaf 1)"    # red
      ADM_COLOR_INF="$(tput setaf 6)"    # cyan
    else
      ADM_COLOR_RST=""; ADM_COLOR_BLD=""; ADM_COLOR_DIM=""
      ADM_COLOR_OK="";  ADM_COLOR_WRN=""; ADM_COLOR_ERR=""
      ADM_COLOR_INF=""
    fi
  else
    ADM_COLOR_RST=""; ADM_COLOR_BLD=""; ADM_COLOR_DIM=""
    ADM_COLOR_OK="";  ADM_COLOR_WRN=""; ADM_COLOR_ERR=""
    ADM_COLOR_INF=""
  fi
}
__adm_setup_colors

# Helpers de saída
adm_info() {  echo -e "${ADM_COLOR_INF}[ADM]${ADM_COLOR_RST} $*"; }
adm_ok()   {  echo -e "${ADM_COLOR_OK}[OK ]${ADM_COLOR_RST} $*"; }
adm_warn() {  echo -e "${ADM_COLOR_WRN}[WAR]${ADM_COLOR_RST} $*" 1>&2; }
adm_err()  {  echo -e "${ADM_COLOR_ERR}[ERR]${ADM_COLOR_RST} $*" 1>&2; }

###############################################################################
# Utilidades gerais
###############################################################################
adm_is_cmd() { command -v "$1" >/dev/null 2>&1; }

adm_require_cmds() {
  local missing=()
  for c in "$@"; do
    adm_is_cmd "$c" || missing+=("$c")
  done
  if ((${#missing[@]})); then
    adm_err "Ferramentas ausentes: ${missing[*]}"
    exit 4
  fi
}

adm_sudo_maybe() {
  if [[ $EUID -ne 0 ]]; then
    if adm_is_cmd sudo; then
      sudo "$@"
    else
      adm_err "Necessário root para executar: $*"
      exit 5
    fi
  else
    "$@"
  fi
}

###############################################################################
# Detecção de CPU/Paralelismo/Linkers/Features
###############################################################################
__adm_detect_parallelism() {
  local n="1"
  if adm_is_cmd nproc; then
    n=$(nproc 2>/dev/null || echo 1)
  elif [[ -r /proc/cpuinfo ]]; then
    n=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
  fi
  if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 )); then n=1; fi
  echo "$n"
}

__adm_detect_ld() {
  # Prefer ld.lld, depois gold, depois bfd
  if adm_is_cmd ld.lld; then
    echo "ld.lld"
  elif adm_is_cmd ld.gold; then
    echo "ld.gold"
  else
    echo "ld"
  fi
}

__adm_supports_lto() {
  # Sinaliza se toolchain suporta -flto
  if adm_is_cmd gcc; then
    echo | gcc -x c - -o /dev/null -flto >/dev/null 2>&1 && return 0
  fi
  if adm_is_cmd clang; then
    echo | clang -x c - -o /dev/null -flto >/dev/null 2>&1 && return 0
  fi
  return 1
}

###############################################################################
# LIBC e TRIPLET
###############################################################################
__adm_validate_libc() {
  local libc="${1:-glibc}"
  case "$libc" in
    glibc|musl) ;;
    *) adm_err "LIBC inválida: $libc (use glibc ou musl)"; exit 6 ;;
  esac
  echo "$libc"
}

__adm_detect_triplet() {
  # tenta -dumpmachine; senão heurística leve
  local triplet=""
  if adm_is_cmd gcc; then
    triplet=$(gcc -dumpmachine 2>/dev/null || true)
  elif adm_is_cmd clang; then
    triplet=$(clang -dumpmachine 2>/dev/null || true)
  fi
  if [[ -z "$triplet" ]]; then
    # Heurística básica por arquitetura
    local arch
    arch=$(uname -m)
    case "$arch" in
      x86_64) triplet="x86_64-pc-linux-gnu" ;;
      aarch64) triplet="aarch64-unknown-linux-gnu" ;;
      armv7l) triplet="armv7l-unknown-linux-gnueabihf" ;;
      riscv64) triplet="riscv64-unknown-linux-gnu" ;;
      *) triplet="${arch}-unknown-linux-gnu" ;;
    esac
  fi
  echo "$triplet"
}

###############################################################################
# Perfis: criação automática e carga segura
###############################################################################
__adm_profile_path() {
  local name="$1"
  echo "${ADM_PROFILES_DIR}/profile-${name}.env"
}

__adm_profiles_defaults() {
  # Retorna conteúdo padrão para cada perfil
  local name="$1" ; local nproc="$2" ; local libc="$3" ; local triplet="$4"
  local ld_bin="$5" ; local lto="$6"

  case "$name" in
    minimo)
      cat <<EOF
# Perfil: minimo (bootstrap/toolchain)
PROFILE_NAME=minimo
LIBC=${libc}
TRIPLET=${triplet}
MAKEFLAGS=-j${nproc}
CC=${CC:-gcc}
CXX=${CXX:-g++}
AR=${AR:-ar}
RANLIB=${RANLIB:-ranlib}
LD=${LD:-${ld_bin}}
CFLAGS="-O1 -pipe"
CXXFLAGS="-O1 -pipe"
LDFLAGS=""
PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/share/pkgconfig"
STRIP_DEBUG="0"
ENABLE_LTO="0"
ENABLE_PGO="0"
BUILD_DOCS="0"
RUN_TESTS="0"
EOF
      ;;
    normal)
      cat <<EOF
# Perfil: normal (equilíbrio)
PROFILE_NAME=normal
LIBC=${libc}
TRIPLET=${triplet}
MAKEFLAGS=-j${nproc}
CC=${CC:-gcc}
CXX=${CXX:-g++}
AR=${AR:-ar}
RANLIB=${RANLIB:-ranlib}
LD=${LD:-${ld_bin}}
CFLAGS="-O2 -pipe -fno-plt"
CXXFLAGS="-O2 -pipe -fno-plt"
LDFLAGS=""
PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/share/pkgconfig"
STRIP_DEBUG="1"
ENABLE_LTO="${lto}"
ENABLE_PGO="0"
BUILD_DOCS="1"
RUN_TESTS="1"
EOF
      ;;
    aggressive)
      cat <<EOF
# Perfil: aggressive (máxima performance)
PROFILE_NAME=aggressive
LIBC=${libc}
TRIPLET=${triplet}
MAKEFLAGS=-j${nproc}
CC=${CC:-gcc}
CXX=${CXX:-g++}
AR=${AR:-ar}
RANLIB=${RANLIB:-ranlib}
LD=${LD:-${ld_bin}}
CFLAGS="-O3 -pipe -fno-plt -fuse-linker-plugin -march=native"
CXXFLAGS="-O3 -pipe -fno-plt -fuse-linker-plugin -march=native"
LDFLAGS="-Wl,-O1"
PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/share/pkgconfig"
STRIP_DEBUG="1"
ENABLE_LTO="${lto}"
ENABLE_PGO="0"
BUILD_DOCS="1"
RUN_TESTS="1"
EOF
      ;;
    *)
      adm_err "Perfil desconhecido: ${name}"
      exit 7
      ;;
  esac
}

__adm_ensure_profiles_exist() {
  # Cria dir e perfis se não existirem, com perms corretas
  __adm_ensure_dir "$ADM_PROFILES_DIR" "0755" "root" "root"

  local libc="${LIBC:-glibc}"
  libc="$(__adm_validate_libc "$libc")"

  local triplet="${TRIPLET:-$(__adm_detect_triplet)}"
  local nproc="$(__adm_detect_parallelism)"
  local ld_bin="$(__adm_detect_ld)"
  local lto="0"
  __adm_supports_lto && lto="1"

  local p
  for p in minimo normal aggressive; do
    local pf="$(__adm_profile_path "$p")"
    if [[ ! -f "$pf" ]]; then
      adm_info "Criando perfil padrão: $p → $pf"
      local tmp="${ADM_TMPDIR}/.$$.$RANDOM.profile"
      __adm_profiles_defaults "$p" "$nproc" "$libc" "$triplet" "$ld_bin" "$lto" > "$tmp"
      chmod 0644 "$tmp"
      adm_sudo_maybe mv -f "$tmp" "$pf"
      adm_sudo_maybe chown root:root "$pf" || true
    fi
  done
}

# Lista reduzida de variáveis permitidas em perfis
ADM_PROFILE_ALLOWED_VARS=(
  PROFILE_NAME LIBC TRIPLET MAKEFLAGS
  CC CXX AR RANLIB LD
  CFLAGS CXXFLAGS LDFLAGS PKG_CONFIG_PATH
  STRIP_DEBUG ENABLE_LTO ENABLE_PGO BUILD_DOCS RUN_TESTS
)

__adm_safe_source_profile() {
  # "Sourcing" defensivo: só exporta variáveis da whitelist
  local f="$1"
  [[ -r "$f" ]] || { adm_err "Perfil não legível: $f"; exit 8; }

  # shellcheck disable=SC1090
  source "$f"

  local v
  for v in "${ADM_PROFILE_ALLOWED_VARS[@]}"; do
    if [[ -v "$v" ]]; then
      # Sanitização simples (sem quebras de linha)
      local val sanitized
      val="${!v}"
      sanitized="${val//$'\n'/ }"
      export "$v=$sanitized"
    fi
  done

  # Ajustes condicionais
  if [[ "${ENABLE_LTO:-0}" == "1" ]]; then
    export CFLAGS="${CFLAGS:-} -flto"
    export CXXFLAGS="${CXXFLAGS:-} -flto"
    export LDFLAGS="${LDFLAGS:-} -flto"
  fi
  if [[ "${ENABLE_PGO:-0}" == "1" ]]; then
    # Apenas marca; os estágios pgo-build medirão/usarão
    export ADM_PGO_ENABLED=1
  else
    export ADM_PGO_ENABLED=0
  fi

  # Defaults seguros
  export CC="${CC:-gcc}"
  export CXX="${CXX:-g++}"
  export AR="${AR:-ar}"
  export RANLIB="${RANLIB:-ranlib}"
  export LD="${LD:-$(__adm_detect_ld)}"
  export MAKEFLAGS="${MAKEFLAGS:-"-j$(__adm_detect_parallelism)"}"
  export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-/usr/lib/pkgconfig:/usr/share/pkgconfig}"

  # Confirmar libc/triplet finais
  export LIBC="$(__adm_validate_libc "${LIBC:-glibc}")"
  export TRIPLET="${TRIPLET:-$(__adm_detect_triplet)}"
}

###############################################################################
# API pública do script
###############################################################################
adm_profiles_init() {
  __adm_ensure_profiles_exist
  local want="${1:-normal}"  # padrão: normal
  local pf="$(__adm_profile_path "$want")"
  if [[ ! -f "$pf" ]]; then
    adm_err "Perfil solicitado não existe: $want"
    exit 9
  fi
  __adm_safe_source_profile "$pf"

  adm_ok "Perfil carregado: ${PROFILE_NAME:-?} | LIBC=${LIBC} | TRIPLET=${TRIPLET} | MAKEFLAGS=${MAKEFLAGS}"
  adm_info "Toolchain: CC=${CC} CXX=${CXX} LD=${LD} AR=${AR} RANLIB=${RANLIB}"
  adm_info "Flags: CFLAGS='${CFLAGS:-}' CXXFLAGS='${CXXFLAGS:-}' LDFLAGS='${LDFLAGS:-}'"
  adm_info "Docs=${BUILD_DOCS:-0} Tests=${RUN_TESTS:-0} LTO=${ENABLE_LTO:-0} PGO=${ENABLE_PGO:-0}"
}

# Execução direta (opcional): permite testar rapidamente
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # Perfil pode ser passado via $1; LIBC/TRIPLET via env
  adm_profiles_init "${1:-normal}"
fi
###############################################################################
# Extensões e correções de possíveis problemas
# (mantidas separadas para facilitar manutenção)
###############################################################################
# Corrige um problema comum: variáveis com espaços extras ou aspas perdidas
adm_sanitize_flags() {
  local trim
  trim() { sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//' ; }
  export CFLAGS="$(echo -n "${CFLAGS:-}"   | tr -s ' ' | trim)"
  export CXXFLAGS="$(echo -n "${CXXFLAGS:-}" | tr -s ' ' | trim)"
  export LDFLAGS="$(echo -n "${LDFLAGS:-}"  | tr -s ' ' | trim)"
  export MAKEFLAGS="$(echo -n "${MAKEFLAGS:-}" | tr -s ' ' | trim)"
}
adm_sanitize_flags

# Normaliza locale/TZ para builds consistentes
adm_normalize_locale() {
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-$LANG}"
  export TZ="${TZ:-UTC}"
}
adm_normalize_locale

# Umask padrão segura p/ artefatos de build
umask 022

# Prepara TMPDIR com perms seguras
__adm_ensure_dir "$ADM_TMPDIR" "0755" "root" "root"

# Verifica suporte a linkers/flags e avisa com detalhes, sem falhar
adm_capability_report() {
  local lto_msg="sem LTO"
  if [[ "${ENABLE_LTO:-0}" == "1" ]]; then
    lto_msg="com LTO"
  fi
  local pgo_msg="sem PGO"
  [[ "${ADM_PGO_ENABLED:-0}" == "1" ]] && pgo_msg="com PGO"

  adm_info "Capacidades: ${lto_msg}, ${pgo_msg}; Linker preferido: ${LD:-ld}"
  if [[ "${LD:-ld}" == "ld" ]]; then
    adm_warn "ld padrão em uso; ld.lld/ld.gold podem acelerar o link."
  fi
}
adm_capability_report

# Guardas adicionais contra erros silenciosos de variáveis
adm_guard_required_env() {
  local missing=()
  for v in CC CXX AR RANLIB LD MAKEFLAGS LIBC TRIPLET; do
    [[ -v $v ]] || missing+=("$v")
  done
  if ((${#missing[@]})); then
    adm_err "Variáveis obrigatórias ausentes: ${missing[*]}"
    exit 10
  fi
}
adm_guard_required_env

# Export final explícito (evita “sourcing” parcial em shells antigos)
export CC CXX AR RANLIB LD MAKEFLAGS LIBC TRIPLET CFLAGS CXXFLAGS LDFLAGS \
       PKG_CONFIG_PATH STRIP_DEBUG ENABLE_LTO ENABLE_PGO BUILD_DOCS RUN_TESTS \
       ADM_ROOT ADM_SCRIPTS_DIR ADM_PROFILES_DIR ADM_TMPDIR ADM_STATE_DIR

# Mensagem final de “pronto”
adm_ok "Ambiente ADM inicializado."
