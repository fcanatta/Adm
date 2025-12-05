#!/usr/bin/env bash
# Script de construção do pacote: Glibc 2.42
#
# Chamado pelo adm assim:
#   bash glibc.sh build <libc>
#
# Variáveis importantes exportadas pelo adm:
#   ADM_CATEGORY      - categoria do pacote (ex: "libc")
#   ADM_PKG_NAME      - nome do pacote (ex: "glibc")
#   ADM_LIBC          - tipo de libc alvo (para este pacote, espera-se "glibc")
#   ADM_ROOTFS        - rootfs alvo (onde a libc será usada, ex: /opt/systems/glibc-rootfs)
#   ADM_CACHE_SRC     - cache de fontes (ex: /var/cache/adm/sources)
#   ADM_CACHE_PKG     - cache de pacotes binários
#   ADM_BUILD_ROOT    - diretório de build temporário
#   ADM_DESTDIR       - diretório DESTDIR onde será instalado para empacotamento
#
# Este script faz:
#   - download do tarball glibc-2.42
#   - build em diretório separado (out-of-tree)
#   - instalação em ${ADM_DESTDIR} usando make install_root=... install
#
# NOTA: Assume que os Linux API headers corretos já estão instalados em:
#   ${ADM_ROOTFS}/usr/include
#
# É possível ajustar várias coisas via variáveis de ambiente:
#   ADM_GLIBC_TARBALL_URL    - URL alternativa para o tarball
#   ADM_GLIBC_TARGET         - triplet de host (ex: x86_64-pc-linux-gnu)
#   ADM_GLIBC_BUILD_TRIPLET  - triplet de build (default: $(gcc -dumpmachine))
#   ADM_GLIBC_MIN_KERNEL     - versão mínima do kernel, ex: 4.14 (default)
#   ADM_GLIBC_SLIBDIR        - slibdir (/usr/lib ou /usr/lib64, default: /usr/lib)
#   ADM_GLIBC_EXTRA_CONFIG   - string extra de opções para o configure
#   ADM_GLIBC_RUN_TESTS      - se "1", roda "make check" (pode ser bem demorado)
#   ADM_MAKE_JOBS            - número de jobs do make (default: nproc ou 1)
#
# O adm usará PKG_VERSION exportada aqui para registrar a versão do pacote.

set -euo pipefail

GLIBC_VERSION="2.42"
GLIBC_NAME="glibc-${GLIBC_VERSION}"

: "${ADM_CACHE_SRC:=/var/cache/adm/sources}"
: "${ADM_BUILD_ROOT:=/tmp/adm-build-${ADM_CATEGORY:-libc}-${ADM_PKG_NAME:-glibc}-${ADM_LIBC:-glibc}}"
: "${ADM_DESTDIR:=${ADM_BUILD_ROOT}/destdir}"
: "${ADM_ROOTFS:=/}"

TARBALL="${GLIBC_NAME}.tar.xz"
DEFAULT_URL="https://ftp.gnu.org/gnu/libc/${TARBALL}"
GLIBC_URL="${ADM_GLIBC_TARBALL_URL:-$DEFAULT_URL}"

SRC_ARCHIVE="${ADM_CACHE_SRC}/${TARBALL}"
SRC_DIR="${ADM_BUILD_ROOT}/${GLIBC_NAME}"
BUILD_DIR="${ADM_BUILD_ROOT}/glibc-build"

###############################################################################
# FUNÇÕES AUXILIARES
###############################################################################

log()  { printf '[glibc] %s\n' "$*"; }
die()  { printf '[glibc][ERRO] %s\n' "$*" >&2; exit 1; }

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

  log "Baixando Glibc ${GLIBC_VERSION} de: $GLIBC_URL"
  if has_cmd curl; then
    curl -L -o "$SRC_ARCHIVE" "$GLIBC_URL"
  elif has_cmd wget; then
    wget -O "$SRC_ARCHIVE" "$GLIBC_URL"
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

build_glibc() {
  # Sanity básico
  if [ "${ADM_LIBC:-glibc}" != "glibc" ]; then
    log "Aviso: ADM_LIBC='${ADM_LIBC:-}' (esperado 'glibc' para este pacote). Continuando mesmo assim."
  fi

  ensure_tools
  fetch_source
  extract_source

  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR" "$ADM_DESTDIR"

  log "Rootfs alvo (para headers e execução futura): ${ADM_ROOTFS}"
  if [ ! -d "${ADM_ROOTFS}/usr/include" ]; then
    log "Aviso: ${ADM_ROOTFS}/usr/include não existe. Certifique-se de ter instalado os Linux API headers."
  fi

  # Triplets de build/host
  local build_triplet host_triplet
  build_triplet="${ADM_GLIBC_BUILD_TRIPLET:-$(gcc -dumpmachine)}"
  host_triplet="${ADM_GLIBC_TARGET:-$build_triplet}"

  local min_kernel slibdir extra_cfg jobs
  min_kernel="${ADM_GLIBC_MIN_KERNEL:-4.14}"
  slibdir="${ADM_GLIBC_SLIBDIR:-/usr/lib}"
  extra_cfg="${ADM_GLIBC_EXTRA_CONFIG:-}"
  jobs="${ADM_MAKE_JOBS:-$(nproc_safe)}"

  log "Triplets:"
  log "  build = ${build_triplet}"
  log "  host  = ${host_triplet}"
  log "Configuração:"
  log "  min kernel = ${min_kernel}"
  log "  slibdir    = ${slibdir}"
  log "  jobs       = ${jobs}"
  [ -n "$extra_cfg" ] && log "  extra cfg  = ${extra_cfg}"

  cd "$BUILD_DIR"

  # Algumas variáveis de cache do configure (importante pra scripts não perguntarem)
  export libc_cv_slibdir="${slibdir}"

  log "Rodando configure da glibc..."
  "../${GLIBC_NAME}/configure" \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localedir=/usr/share/locale \
    --with-headers="${ADM_ROOTFS%/}/usr/include" \
    --enable-kernel="${min_kernel}" \
    --disable-werror \
    --build="${build_triplet}" \
    --host="${host_triplet}" \
    $extra_cfg

  log "Compilando glibc (make -j${jobs})..."
  make -j"${jobs}"

  if [ "${ADM_GLIBC_RUN_TESTS:-0}" = "1" ]; then
    log "ADM_GLIBC_RUN_TESTS=1: executando 'make check' (pode levar bastante tempo)..."
    # Os testes da glibc são bem pesados; em muitos ambientes, pode ser desejável rodar só um subset.
    # Aqui rodamos o make check completo se solicitado.
    make check || log "Aviso: 'make check' retornou erro. Verifique os logs em ${BUILD_DIR}."
  fi

  log "Instalando glibc em install_root='${ADM_DESTDIR}' (prefix=/usr)..."
  # Para glibc, a forma recomendada é usar install_root em vez de DESTDIR
  make install_root="${ADM_DESTDIR}" install

  # Informar versão ao adm (usado por adm_finalize_build)
  export PKG_VERSION="$GLIBC_VERSION"

  log "Glibc ${GLIBC_VERSION} instalada em ${ADM_DESTDIR} (para empacotamento pelo adm)."
}

clean_glibc() {
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
      build_glibc
      ;;

    clean)
      clean_glibc
      ;;

    *)
      cat <<EOF
Uso: $(basename "$0") <ação> [libc]

Ações suportadas:
  download   - baixa o tarball da glibc (${TARBALL}) para o cache
  build      - compila e instala a glibc em ADM_DESTDIR (para empacotamento)
  clean      - remove o diretório de build (ADM_BUILD_ROOT)

Este script é normalmente chamado pelo 'adm' com:
  adm build ${ADM_CATEGORY:-libc}/${ADM_PKG_NAME:-glibc} [libc]

Principais variáveis de ajuste (opcionais):
  ADM_GLIBC_TARBALL_URL   - URL alternativa do tarball
  ADM_GLIBC_TARGET        - triplet de host (ex: x86_64-pc-linux-gnu)
  ADM_GLIBC_BUILD_TRIPLET - triplet de build (default: \$(gcc -dumpmachine))
  ADM_GLIBC_MIN_KERNEL    - versão mínima do kernel (default: 4.14)
  ADM_GLIBC_SLIBDIR       - slibdir (default: /usr/lib)
  ADM_GLIBC_EXTRA_CONFIG  - opções extras para o configure
  ADM_GLIBC_RUN_TESTS     - se "1", roda 'make check'
  ADM_MAKE_JOBS           - número de jobs do make (default: nproc ou 1)

EOF
      ;;
  esac
}

main "$@"
