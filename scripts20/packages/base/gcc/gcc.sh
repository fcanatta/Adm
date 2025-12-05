#!/usr/bin/env bash
# Script de construção do pacote: GCC 15.2.0 (C + C++)
#
# Chamado pelo adm assim:
#   bash gcc.sh build <libc>
#
# Variáveis exportadas pelo adm:
#   ADM_CATEGORY      - categoria do pacote (ex: "toolchain")
#   ADM_PKG_NAME      - nome do pacote (ex: "gcc")
#   ADM_LIBC          - libc alvo ("glibc", "musl"...)
#   ADM_ROOTFS        - rootfs onde o gcc/libstdc++ serão usados (ex: /opt/systems/glibc-rootfs)
#   ADM_CACHE_SRC     - cache de fontes (ex: /var/cache/adm/sources)
#   ADM_CACHE_PKG     - cache de pacotes binários
#   ADM_BUILD_ROOT    - diretório de build temporário
#   ADM_DESTDIR       - DESTDIR de instalação (virará / dentro do rootfs)
#
# O que este script faz:
#   - baixa o tarball gcc-15.2.0
#   - compila GCC com C + C++ (libstdc++-v3 junto)
#   - instala em ${ADM_DESTDIR} com prefix=/usr
#
# Requisitos (devem estar instalados no sistema de build):
#   - gmp, mpfr, mpc, isl (libs usadas pelo GCC)
#
# Variáveis de ajuste (opcionais):
#   ADM_GCC_TARBALL_URL      - URL alternativa do tarball
#   ADM_GCC_BUILD_TRIPLET    - triplet de build (default: $(gcc -dumpmachine))
#   ADM_GCC_TARGET           - triplet de host/target (default: = build)
#   ADM_GCC_PREFIX           - prefix de instalação (default: /usr)
#   ADM_GCC_ENABLE_NLS       - se "1", NÃO passa --disable-nls
#   ADM_GCC_EXTRA_CONFIG     - string com opções extras pra ./configure
#   ADM_GCC_RUN_TESTS        - se "1", roda 'make -k check' (demorado)
#   ADM_GCC_DISABLE_BOOTSTRAP - se "0", deixa bootstrap ligado; default: 1 (desliga bootstrap)
#   ADM_MAKE_JOBS            - número de jobs no make (default: nproc ou 1)
#
# O adm usará PKG_VERSION exportada aqui para registrar a versão do pacote.

set -euo pipefail

GCC_VERSION="15.2.0"
GCC_NAME="gcc-${GCC_VERSION}"

: "${ADM_CACHE_SRC:=/var/cache/adm/sources}"
: "${ADM_BUILD_ROOT:=/tmp/adm-build-${ADM_CATEGORY:-toolchain}-${ADM_PKG_NAME:-gcc}-${ADM_LIBC:-glibc}}"
: "${ADM_DESTDIR:=${ADM_BUILD_ROOT}/destdir}"
: "${ADM_ROOTFS:=/}"

TARBALL="${GCC_NAME}.tar.xz"
DEFAULT_URL="https://ftp.gnu.org/gnu/gcc/${GCC_NAME}/${TARBALL}"
GCC_URL="${ADM_GCC_TARBALL_URL:-$DEFAULT_URL}"

SRC_ARCHIVE="${ADM_CACHE_SRC}/${TARBALL}"
SRC_DIR="${ADM_BUILD_ROOT}/${GCC_NAME}"
BUILD_DIR="${ADM_BUILD_ROOT}/gcc-build"

###############################################################################
# FUNÇÕES AUXILIARES
###############################################################################

log()  { printf '[gcc] %s\n' "$*"; }
die()  { printf '[gcc][ERRO] %s\n' "$*" >&2; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

nproc_safe() {
  if has_cmd nproc; then
    nproc
  else
    echo 1
  fi
}

ensure_tools() {
  local missing=()
  for cmd in tar make gcc; do
    has_cmd "$cmd" || missing+=("$cmd")
  done

  # Se não houver tarball em cache, precisamos de curl ou wget
  if [ ! -f "$SRC_ARCHIVE" ]; then
    if ! has_cmd curl && ! has_cmd wget; then
      missing+=("curl/wget")
    fi
  fi

  if ((${#missing[@]} > 0)); then
    die "Ferramentas necessárias ausentes: ${missing[*]}"
  fi
}

fetch_source() {
  mkdir -p "$ADM_CACHE_SRC"

  if [ -f "$SRC_ARCHIVE" ]; then
    log "Tarball já presente em cache: $SRC_ARCHIVE"
    return 0
  fi

  log "Baixando GCC ${GCC_VERSION} de: $GCC_URL"
  if has_cmd curl; then
    curl -L -o "$SRC_ARCHIVE" "$GCC_URL"
  elif has_cmd wget; then
    wget -O "$SRC_ARCHIVE" "$GCC_URL"
  else
    die "Nem curl nem wget disponíveis para download e tarball ausente: $SRC_ARCHIVE"
  fi
}

extract_source() {
  rm -rf "$SRC_DIR"
  mkdir -p "$ADM_BUILD_ROOT"

  log "Extraindo ${SRC_ARCHIVE} em ${ADM_BUILD_ROOT}"
  tar -xf "$SRC_ARCHIVE" -C "$ADM_BUILD_ROOT"

  if [ ! -d "$SRC_DIR" ]; then
    die "Diretório de fonte esperado não encontrado após extração: $SRC_DIR"
  fi
}

###############################################################################
# BUILD / INSTALL
###############################################################################

build_gcc() {
  ensure_tools
  fetch_source
  extract_source

  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR" "$ADM_DESTDIR"

  local build_triplet host_triplet target_triplet prefix extra_cfg jobs
  build_triplet="${ADM_GCC_BUILD_TRIPLET:-$(gcc -dumpmachine)}"
  host_triplet="${ADM_GCC_TARGET:-$build_triplet}"
  target_triplet="$host_triplet"
  prefix="${ADM_GCC_PREFIX:-/usr}"
  extra_cfg="${ADM_GCC_EXTRA_CONFIG:-}"
  jobs="${ADM_MAKE_JOBS:-$(nproc_safe)}"

  log "Triplets:"
  log "  build  = ${build_triplet}"
  log "  host   = ${host_triplet}"
  log "  target = ${target_triplet}"
  log "Configuração:"
  log "  prefix   = ${prefix}"
  log "  rootfs   = ${ADM_ROOTFS}"
  log "  jobs     = ${jobs}"
  [ -n "$extra_cfg" ] && log "  extra cfg= ${extra_cfg}"

  # Avisos de sanidade
  if [ ! -d "${ADM_ROOTFS%/}/usr/include" ]; then
    log "Aviso: ${ADM_ROOTFS%/}/usr/include não existe. Certifique-se de ter instalado glibc+headers."
  fi

  cd "$BUILD_DIR"

  # Args de configure
  local cfg_args=(
    "../${GCC_NAME}/configure"
    "--prefix=${prefix}"
    "--build=${build_triplet}"
    "--host=${host_triplet}"
    "--target=${target_triplet}"
    "--enable-languages=c,c++"
    "--enable-shared"
    "--enable-threads=posix"
    "--enable-__cxa_atexit"
    "--enable-lto"
    "--enable-plugin"
    "--enable-default-pie"
    "--enable-default-ssp"
    "--disable-multilib"
    "--disable-werror"
    "--with-system-zlib"
    "--with-native-system-header-dir=/usr/include"
  )

  # Usar sysroot se ADM_ROOTFS não for "/"
  if [ "${ADM_ROOTFS%/}" != "/" ]; then
    cfg_args+=("--with-sysroot=${ADM_ROOTFS%/}")
  fi

  # NLS (traduções)
  if [ "${ADM_GCC_ENABLE_NLS:-0}" != "1" ]; then
    cfg_args+=("--disable-nls")
  fi

  # Bootstrap
  if [ "${ADM_GCC_DISABLE_BOOTSTRAP:-1}" = "1" ]; then
    cfg_args+=("--disable-bootstrap")
  fi

  # Opções extras
  if [ -n "$extra_cfg" ]; then
    # shellcheck disable=SC2206
    extra_array=( $extra_cfg )
    cfg_args+=("${extra_array[@]}")
  fi

  log "Rodando configure do GCC..."
  "${cfg_args[@]}"

  log "Compilando GCC (make -j${jobs})..."
  make -j"${jobs}"

  if [ "${ADM_GCC_RUN_TESTS:-0}" = "1" ]; then
    log "ADM_GCC_RUN_TESTS=1: executando 'make -k check' (pode ser bem demorado)..."
    make -k check || log "Aviso: 'make -k check' retornou erro. Verifique os logs em ${BUILD_DIR}."
  fi

  log "Instalando GCC em DESTDIR='${ADM_DESTDIR}' (prefix=${prefix})..."
  make DESTDIR="${ADM_DESTDIR}" install

  # Informar versão ao adm (usado por adm_finalize_build)
  export PKG_VERSION="$GCC_VERSION"

  log "GCC ${GCC_VERSION} (C + C++) instalado em ${ADM_DESTDIR}${prefix} (para empacotamento pelo adm)."
}

clean_gcc() {
  log "Limpando diretório de build: $ADM_BUILD_ROOT"
  rm -rf "$ADM_BUILD_ROOT"
}

###############################################################################
# DISPATCH
###############################################################################

main() {
  local action="${1:-}"

  case "$action" in
    download)
      ensure_tools
      fetch_source
      ;;

    build)
      # $2 é a libc passada pelo adm, mas não precisamos dela aqui
      shift || true
      build_gcc
      ;;

    clean)
      clean_gcc
      ;;

    *)
      cat <<EOF
Uso: $(basename "$0") <ação> [libc]

Ações suportadas:
  download   - baixa o tarball do GCC (${TARBALL}) para o cache
  build      - compila e instala o GCC (C + C++) em ADM_DESTDIR (para empacotamento)
  clean      - remove o diretório de build (ADM_BUILD_ROOT)

Fluxo típico com adm:
  adm build ${ADM_CATEGORY:-toolchain}/${ADM_PKG_NAME:-gcc} glibc
  adm install ${ADM_CATEGORY:-toolchain}/${ADM_PKG_NAME:-gcc} glibc

Variáveis de ajuste (opcionais):
  ADM_GCC_TARBALL_URL       - URL alternativa do tarball
  ADM_GCC_BUILD_TRIPLET     - triplet de build (default: \$(gcc -dumpmachine))
  ADM_GCC_TARGET            - triplet de host/target
  ADM_GCC_PREFIX            - prefix (default: /usr)
  ADM_GCC_ENABLE_NLS        - se "1", não passa --disable-nls
  ADM_GCC_EXTRA_CONFIG      - opções extras para o configure
  ADM_GCC_RUN_TESTS         - se "1", roda 'make -k check'
  ADM_GCC_DISABLE_BOOTSTRAP - se "0", mantém bootstrap habilitado (default: desabilita)
  ADM_MAKE_JOBS             - número de jobs do make (default: nproc ou 1)

EOF
      ;;
  esac
}

main "$@"
