#!/usr/bin/env bash
# Script de construção do pacote: Binutils 2.45.1
#
# Chamado pelo adm assim:
#   bash binutils.sh build <libc>
#
# Variáveis exportadas pelo adm:
#   ADM_CATEGORY      - categoria do pacote (ex: "toolchain")
#   ADM_PKG_NAME      - nome do pacote (ex: "binutils")
#   ADM_LIBC          - libc alvo ("glibc", "musl", etc) – não é crítico aqui
#   ADM_ROOTFS        - rootfs alvo (onde os binários vão rodar, ex: /opt/systems/glibc-rootfs)
#   ADM_CACHE_SRC     - cache de fontes (ex: /var/cache/adm/sources)
#   ADM_CACHE_PKG     - cache de pacotes binários
#   ADM_BUILD_ROOT    - diretório de build temporário
#   ADM_DESTDIR       - diretório DESTDIR para instalação (virará / no rootfs)
#
# Este script faz:
#   - download do tarball binutils-2.45.1
#   - build em diretório separado (out-of-tree)
#   - instalação em ${ADM_DESTDIR} com prefix=/usr
#
# Ajustes por ambiente (opcionais):
#   ADM_BINUTILS_TARBALL_URL   - URL alternativa do tarball
#   ADM_BINUTILS_BUILD_TRIPLET - triplet de build (default: $(gcc -dumpmachine))
#   ADM_BINUTILS_TARGET        - triplet de host/target (default: mesmo que build)
#   ADM_BINUTILS_PREFIX        - prefix de instalação (default: /usr)
#   ADM_BINUTILS_ENABLE_NLS    - se "1", não passa --disable-nls
#   ADM_BINUTILS_EXTRA_CONFIG  - opções extras para o configure
#   ADM_MAKE_JOBS              - número de jobs no make (default: nproc ou 1)
#
# O adm usará PKG_VERSION exportada aqui para registrar a versão do pacote.

set -euo pipefail

# Definir quais libcs esse pacote suporta:
#   - para gcc final: glibc, musl, uclibc-ng
#   - para glibc: apenas glibc
#   - para musl: apenas musl
REQUIRED_LIBCS="glibc musl uclibc-ng"

# Carregar validador de profile
source /usr/src/adm/lib/adm_profile_validate.sh

# Validar profile atual
adm_profile_validate

BINUTILS_VERSION="2.45.1"
BINUTILS_NAME="binutils-${BINUTILS_VERSION}"

: "${ADM_CACHE_SRC:=/var/cache/adm/sources}"
: "${ADM_BUILD_ROOT:=/tmp/adm-build-${ADM_CATEGORY:-toolchain}-${ADM_PKG_NAME:-binutils}-${ADM_LIBC:-glibc}}"
: "${ADM_DESTDIR:=${ADM_BUILD_ROOT}/destdir}"
: "${ADM_ROOTFS:=/}"

TARBALL="${BINUTILS_NAME}.tar.xz"
DEFAULT_URL="https://ftp.gnu.org/gnu/binutils/${TARBALL}"
BINUTILS_URL="${ADM_BINUTILS_TARBALL_URL:-$DEFAULT_URL}"

SRC_ARCHIVE="${ADM_CACHE_SRC}/${TARBALL}"
SRC_DIR="${ADM_BUILD_ROOT}/${BINUTILS_NAME}"
BUILD_DIR="${ADM_BUILD_ROOT}/binutils-build"

###############################################################################
# FUNÇÕES AUXILIARES
###############################################################################

log()  { printf '[binutils] %s\n' "$*"; }
die()  { printf '[binutils][ERRO] %s\n' "$*" >&2; exit 1; }

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

  log "Baixando Binutils ${BINUTILS_VERSION} de: $BINUTILS_URL"
  if has_cmd curl; then
    curl -L -o "$SRC_ARCHIVE" "$BINUTILS_URL"
  elif has_cmd wget; then
    wget -O "$SRC_ARCHIVE" "$BINUTILS_URL"
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

build_binutils() {
  ensure_tools
  fetch_source
  extract_source

  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR" "$ADM_DESTDIR"

  local build_triplet host_triplet prefix extra_cfg jobs
  build_triplet="${ADM_BINUTILS_BUILD_TRIPLET:-$(gcc -dumpmachine)}"
  host_triplet="${ADM_BINUTILS_TARGET:-$build_triplet}"
  prefix="${ADM_BINUTILS_PREFIX:-/usr}"
  extra_cfg="${ADM_BINUTILS_EXTRA_CONFIG:-}"
  jobs="${ADM_MAKE_JOBS:-$(nproc_safe)}"

  log "Triplets:"
  log "  build = ${build_triplet}"
  log "  host  = ${host_triplet}"
  log "Configuração:"
  log "  prefix    = ${prefix}"
  log "  rootfs    = ${ADM_ROOTFS}"
  log "  jobs      = ${jobs}"
  [ -n "$extra_cfg" ] && log "  extra cfg = ${extra_cfg}"

  cd "$BUILD_DIR"

  # Opções padrão de configure (boas para binutils final)
  local cfg_args=(
    "../${BINUTILS_NAME}/configure"
    "--prefix=${prefix}"
    "--build=${build_triplet}"
    "--host=${host_triplet}"
    "--enable-gold"
    "--enable-ld=default"
    "--enable-plugins"
    "--enable-shared"
    "--enable-64-bit-bfd"
    "--disable-werror"
  )

  # Usar sysroot se ADM_ROOTFS não for "/"
  if [ "${ADM_ROOTFS%/}" != "/" ]; then
    cfg_args+=("--with-sysroot=${ADM_ROOTFS%/}")
  fi

  # NLS (traduções) – por padrão desabilito, a menos que peça explicitamente
  if [ "${ADM_BINUTILS_ENABLE_NLS:-0}" != "1" ]; then
    cfg_args+=("--disable-nls")
  fi

  # Opções extras
  if [ -n "$extra_cfg" ]; then
    # shellcheck disable=SC2206
    extra_array=( $extra_cfg )
    cfg_args+=("${extra_array[@]}")
  fi

  log "Rodando configure dos binutils..."
  "${cfg_args[@]}"

  log "Compilando binutils (make -j${jobs})..."
  make -j"${jobs}"

  log "Instalando binutils em DESTDIR='${ADM_DESTDIR}' (prefix=${prefix})..."
  make DESTDIR="${ADM_DESTDIR}" install

  # Informar versão ao adm (usado por adm_finalize_build)
  export PKG_VERSION="$BINUTILS_VERSION"

  log "Binutils ${BINUTILS_VERSION} instalados em ${ADM_DESTDIR}${prefix} (para empacotamento pelo adm)."
}

clean_binutils() {
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
      build_binutils
      ;;

    clean)
      clean_binutils
      ;;

    *)
      cat <<EOF
Uso: $(basename "$0") <ação> [libc]

Ações suportadas:
  download   - baixa o tarball dos binutils (${TARBALL}) para o cache
  build      - compila e instala os binutils em ADM_DESTDIR (para empacotamento)
  clean      - remove o diretório de build (ADM_BUILD_ROOT)

Exemplo com o adm:
  adm build ${ADM_CATEGORY:-toolchain}/${ADM_PKG_NAME:-binutils} [libc]

Variáveis de ajuste (opcionais):
  ADM_BINUTILS_TARBALL_URL   - URL alternativa do tarball
  ADM_BINUTILS_BUILD_TRIPLET - triplet de build (default: \$(gcc -dumpmachine))
  ADM_BINUTILS_TARGET        - triplet de host/target
  ADM_BINUTILS_PREFIX        - prefix (default: /usr)
  ADM_BINUTILS_ENABLE_NLS    - se "1", não passa --disable-nls
  ADM_BINUTILS_EXTRA_CONFIG  - opções extras para o configure
  ADM_MAKE_JOBS              - número de jobs no make (default: nproc ou 1)

EOF
      ;;
  esac
}

main "$@"
