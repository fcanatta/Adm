#!/usr/bin/env bash
# Script de construção do pacote: GNU M4 1.4.20
#
# Chamado pelo adm assim:
#   bash m4.sh build <libc>
#
# Variáveis exportadas pelo adm:
#   ADM_CATEGORY      - categoria do pacote (ex: "core")
#   ADM_PKG_NAME      - nome do pacote (ex: "m4")
#   ADM_LIBC          - libc alvo ("glibc", "musl", etc) – M4 é userland, não depende direto
#   ADM_ROOTFS        - rootfs alvo (onde o m4 vai rodar, ex: /opt/systems/glibc-rootfs)
#   ADM_CACHE_SRC     - cache de fontes (ex: /var/cache/adm/sources)
#   ADM_CACHE_PKG     - cache de pacotes binários
#   ADM_BUILD_ROOT    - diretório de build temporário
#   ADM_DESTDIR       - diretório DESTDIR de instalação (vira / dentro do rootfs)
#
# Este script faz:
#   - download do tarball m4-1.4.20
#   - build em diretório separado (out-of-tree)
#   - instalação em ${ADM_DESTDIR} com prefix=/usr
#
# Variáveis de ajuste (opcionais):
#   ADM_M4_TARBALL_URL   - URL alternativa do tarball
#   ADM_M4_BUILD_TRIPLET - triplet de build (default: $(gcc -dumpmachine))
#   ADM_M4_HOST_TRIPLET  - host triplet (default: igual ao build)
#   ADM_M4_PREFIX        - prefix (default: /usr)
#   ADM_M4_ENABLE_NLS    - se "1", NÃO passa --disable-nls
#   ADM_M4_EXTRA_CONFIG  - string com opções extras pro ./configure
#   ADM_M4_RUN_TESTS     - se "1", roda 'make check'
#   ADM_MAKE_JOBS        - número de jobs no make (default: nproc ou 1)
#
# O adm usa PKG_VERSION exportada aqui para registrar a versão do pacote.

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

M4_VERSION="1.4.20"
M4_NAME="m4-${M4_VERSION}"

: "${ADM_CACHE_SRC:=/var/cache/adm/sources}"
: "${ADM_BUILD_ROOT:=/tmp/adm-build-${ADM_CATEGORY:-core}-${ADM_PKG_NAME:-m4}-${ADM_LIBC:-glibc}}"
: "${ADM_DESTDIR:=${ADM_BUILD_ROOT}/destdir}"
: "${ADM_ROOTFS:=/}"

TARBALL="${M4_NAME}.tar.xz"
DEFAULT_URL="https://ftp.gnu.org/gnu/m4/${TARBALL}"
M4_URL="${ADM_M4_TARBALL_URL:-$DEFAULT_URL}"

SRC_ARCHIVE="${ADM_CACHE_SRC}/${TARBALL}"
SRC_DIR="${ADM_BUILD_ROOT}/${M4_NAME}"
BUILD_DIR="${ADM_BUILD_ROOT}/m4-build"

###############################################################################
# FUNÇÕES AUXILIARES
###############################################################################

log()  { printf '[m4] %s\n' "$*"; }
die()  { printf '[m4][ERRO] %s\n' "$*" >&2; exit 1; }

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

  log "Baixando GNU M4 ${M4_VERSION} de: $M4_URL"
  if has_cmd curl; then
    curl -L -o "$SRC_ARCHIVE" "$M4_URL"
  elif has_cmd wget; then
    wget -O "$SRC_ARCHIVE" "$M4_URL"
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

build_m4() {
  ensure_tools
  fetch_source
  extract_source

  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR" "$ADM_DESTDIR"

  local build_triplet host_triplet prefix extra_cfg jobs
  build_triplet="${ADM_M4_BUILD_TRIPLET:-$(gcc -dumpmachine)}"
  host_triplet="${ADM_M4_HOST_TRIPLET:-$build_triplet}"
  prefix="${ADM_M4_PREFIX:-/usr}"
  extra_cfg="${ADM_M4_EXTRA_CONFIG:-}"
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

  local cfg_args=(
    "../${M4_NAME}/configure"
    "--prefix=${prefix}"
    "--build=${build_triplet}"
    "--host=${host_triplet}"
  )

  # NLS (traduções) – desabilitado por padrão pra toolchain/ambiente mínimo
  if [ "${ADM_M4_ENABLE_NLS:-0}" != "1" ]; then
    cfg_args+=("--disable-nls")
  fi

  # Opções extras do usuário
  if [ -n "$extra_cfg" ]; then
    # shellcheck disable=SC2206
    extra_array=( $extra_cfg )
    cfg_args+=("${extra_array[@]}")
  fi

  log "Rodando configure do M4..."
  "${cfg_args[@]}"

  log "Compilando M4 (make -j${jobs})..."
  make -j"${jobs}"

  if [ "${ADM_M4_RUN_TESTS:-0}" = "1" ]; then
    log "ADM_M4_RUN_TESTS=1: executando 'make check'..."
    make check || log "Aviso: 'make check' retornou erro. Verifique os logs em ${BUILD_DIR}."
  fi

  log "Instalando M4 em DESTDIR='${ADM_DESTDIR}' (prefix=${prefix})..."
  make DESTDIR="${ADM_DESTDIR}" install

  # Informar versão ao adm
  export PKG_VERSION="$M4_VERSION"

  log "GNU M4 ${M4_VERSION} instalado em ${ADM_DESTDIR}${prefix} (para empacotamento pelo adm)."
}

clean_m4() {
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
      # $2 é a libc passada pelo adm; aqui não é usada diretamente
      shift || true
      build_m4
      ;;

    clean)
      clean_m4
      ;;

    *)
      cat <<EOF
Uso: $(basename "$0") <ação> [libc]

Ações suportadas:
  download   - baixa o tarball do M4 (${TARBALL}) para o cache
  build      - compila e instala o M4 em ADM_DESTDIR (para empacotamento)
  clean      - remove o diretório de build (ADM_BUILD_ROOT)

Exemplo com o adm:
  adm build ${ADM_CATEGORY:-core}/${ADM_PKG_NAME:-m4} glibc
  adm install ${ADM_CATEGORY:-core}/${ADM_PKG_NAME:-m4} glibc

Variáveis de ajuste (opcionais):
  ADM_M4_TARBALL_URL   - URL alternativa do tarball
  ADM_M4_BUILD_TRIPLET - triplet de build (default: \$(gcc -dumpmachine))
  ADM_M4_HOST_TRIPLET  - host triplet (default: igual ao build)
  ADM_M4_PREFIX        - prefix (default: /usr)
  ADM_M4_ENABLE_NLS    - se "1", não passa --disable-nls
  ADM_M4_EXTRA_CONFIG  - opções extras para o configure
  ADM_M4_RUN_TESTS     - se "1", roda 'make check'
  ADM_MAKE_JOBS        - número de jobs no make (default: nproc ou 1)

EOF
      ;;
  esac
}

main "$@"
