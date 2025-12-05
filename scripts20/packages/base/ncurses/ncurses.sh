#!/usr/bin/env bash
# Script de construção do pacote: Ncurses 6.5-20250809 (widec)
#
# Chamado pelo adm:
#   adm build core/ncurses glibc
#   adm build core/ncurses musl
#
# Variáveis exportadas pelo adm:
#   ADM_CATEGORY      - categoria do pacote (ex: "core")
#   ADM_PKG_NAME      - nome do pacote (ex: "ncurses")
#   ADM_LIBC          - libc alvo ("glibc", "musl", "uclibc-ng", etc.)
#   ADM_ROOTFS        - rootfs alvo (ex: /opt/systems/glibc-rootfs)
#   ADM_CACHE_SRC     - cache de fontes (ex: /var/cache/adm/sources)
#   ADM_CACHE_PKG     - cache de pacotes binários
#   ADM_BUILD_ROOT    - diretório de build temporário
#   ADM_DESTDIR       - DESTDIR de instalação (vira / dentro do rootfs)
#
# Este script faz:
#   - download do tarball ncurses-6.5-20250809
#   - build out-of-tree
#   - instalação em ${ADM_DESTDIR}${prefix} (prefix /usr por default)
#
# Integração opcional com o sistema de profiles:
#   Se existir /usr/src/adm/lib/adm_profile_validate.sh, ele é carregado
#   e adm_profile_validate() é chamado no início.
#
# Variáveis de ajuste (opcionais):
#   ADM_NCURSES_TARBALL_URL   - URL alternativa do tarball
#   ADM_NCURSES_BUILD_TRIPLET - triplet de build (default: $(gcc -dumpmachine))
#   ADM_NCURSES_HOST_TRIPLET  - triplet de host (default: build)
#   ADM_NCURSES_PREFIX        - prefix de instalação (default: /usr)
#   ADM_NCURSES_LIBDIR        - libdir (default: ${ADM_NCURSES_PREFIX}/lib)
#   ADM_NCURSES_ENABLE_NLS    - se "1", NÃO passa --disable-nls
#   ADM_NCURSES_WITH_ADA      - se "1", tenta habilitar suporte a Ada (default: 0)
#   ADM_NCURSES_EXTRA_CONFIG  - string com opções extras para o configure
#   ADM_NCURSES_RUN_TESTS     - se "1", tenta rodar 'make check' (limitado)
#   ADM_MAKE_JOBS             - número de jobs no make (default: nproc ou 1)
#
# O adm usará PKG_VERSION exportada aqui para registrar a versão do pacote.

set -euo pipefail

NCURSES_VERSION="6.5-20250809"
NCURSES_NAME="ncurses-${NCURSES_VERSION}"

: "${ADM_CACHE_SRC:=/var/cache/adm/sources}"
: "${ADM_BUILD_ROOT:=/tmp/adm-build-${ADM_CATEGORY:-core}-${ADM_PKG_NAME:-ncurses}-${ADM_LIBC:-glibc}}"
: "${ADM_DESTDIR:=${ADM_BUILD_ROOT}/destdir}"
: "${ADM_ROOTFS:=/}"

# Nome padrão do tarball. Ajuste ADM_NCURSES_TARBALL_URL se o arquivo real tiver outro nome/extensão.
TARBALL="${NCURSES_NAME}.tar.gz"
DEFAULT_URL="https://ftp.gnu.org/pub/gnu/ncurses/${TARBALL}"
NCURSES_URL="${ADM_NCURSES_TARBALL_URL:-$DEFAULT_URL}"

SRC_ARCHIVE="${ADM_CACHE_SRC}/${TARBALL}"
SRC_DIR="${ADM_BUILD_ROOT}/${NCURSES_NAME}"
BUILD_DIR="${ADM_BUILD_ROOT}/ncurses-build"

###############################################################################
# (Opcional) validação de profile
###############################################################################

if [ -f /usr/src/adm/lib/adm_profile_validate.sh ]; then
  # shellcheck disable=SC1091
  . /usr/src/adm/lib/adm_profile_validate.sh
  # ncurses é userland e pode rodar sobre qualquer libc; não definimos REQUIRED_LIBCS.
  adm_profile_validate
fi

###############################################################################
# FUNÇÕES AUXILIARES
###############################################################################

log()  { printf '[ncurses] %s\n' "$*"; }
die()  { printf '[ncurses][ERRO] %s\n' "$*" >&2; exit 1; }

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

  log "Baixando Ncurses ${NCURSES_VERSION} de: $NCURSES_URL"
  if has_cmd curl; then
    curl -L -o "$SRC_ARCHIVE" "$NCURSES_URL"
  elif has_cmd wget; then
    wget -O "$SRC_ARCHIVE" "$NCURSES_URL"
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

build_ncurses() {
  ensure_tools
  fetch_source
  extract_source

  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR" "$ADM_DESTDIR"

  local build_triplet host_triplet prefix libdir extra_cfg jobs
  build_triplet="${ADM_NCURSES_BUILD_TRIPLET:-$(gcc -dumpmachine)}"
  host_triplet="${ADM_NCURSES_HOST_TRIPLET:-$build_triplet}"
  prefix="${ADM_NCURSES_PREFIX:-/usr}"
  libdir="${ADM_NCURSES_LIBDIR:-${prefix}/lib}"
  extra_cfg="${ADM_NCURSES_EXTRA_CONFIG:-}"
  jobs="${ADM_MAKE_JOBS:-$(nproc_safe)}"

  log "Triplets:"
  log "  build = ${build_triplet}"
  log "  host  = ${host_triplet}"
  log "Configuração:"
  log "  prefix    = ${prefix}"
  log "  libdir    = ${libdir}"
  log "  rootfs    = ${ADM_ROOTFS}"
  log "  jobs      = ${jobs}"
  [ -n "$extra_cfg" ] && log "  extra cfg = ${extra_cfg}"

  cd "$BUILD_DIR"

  # Terminfo paths padrão
  local terminfo_dir="/usr/share/terminfo"

  local cfg_args=(
    "../${NCURSES_NAME}/configure"
    "--prefix=${prefix}"
    "--libdir=${libdir}"
    "--build=${build_triplet}"
    "--host=${host_triplet}"
    "--mandir=/usr/share/man"
    "--with-shared"
    "--with-termlib"
    "--enable-widec"
    "--enable-pc-files"
    "--with-pkg-config-libdir=${libdir}/pkgconfig"
    "--with-manpage-format=normal"
    "--with-manpage-colors"
    "--with-manpage-tbl"
    "--with-default-terminfo-dir=${terminfo_dir}"
    "--with-terminfo-dirs=${terminfo_dir}"
    "--without-debug"
    "--without-normal"
  )

  # NLS (traduções) – por padrão desabilita para ambientes mínimos
  if [ "${ADM_NCURSES_ENABLE_NLS:-0}" != "1" ]; then
    cfg_args+=("--disable-nls")
  fi

  # Ada – desabilitada por padrão (é bem chatinho e raramente necessário)
  if [ "${ADM_NCURSES_WITH_ADA:-0}" != "1" ]; then
    cfg_args+=("--without-ada")
  fi

  # Opções extras do usuário
  if [ -n "$extra_cfg" ]; then
    # shellcheck disable=SC2206
    local extra_array=( $extra_cfg )
    cfg_args+=("${extra_array[@]}")
  fi

  # Se ADM_ROOTFS != "/", podemos ajustar CPPFLAGS/LDFLAGS com sysroot
  if [ "${ADM_ROOTFS%/}" != "/" ]; then
    export CPPFLAGS="--sysroot=${ADM_ROOTFS%/} ${CPPFLAGS:-}"
    export LDFLAGS="--sysroot=${ADM_ROOTFS%/} ${LDFLAGS:-}"
    log "Aplicando sysroot em CPPFLAGS/LDFLAGS: --sysroot=${ADM_ROOTFS%/}"
  fi

  log "Rodando configure do ncurses..."
  "${cfg_args[@]}"

  log "Compilando ncurses (make -j${jobs})..."
  make -j"${jobs}"

  if [ "${ADM_NCURSES_RUN_TESTS:-0}" = "1" ]; then
    log "ADM_NCURSES_RUN_TESTS=1: tentando executar 'make check'..."
    make check || log "Aviso: 'make check' retornou erro. Verifique os logs em ${BUILD_DIR}."
  fi

  log "Instalando ncurses em DESTDIR='${ADM_DESTDIR}' (prefix=${prefix})..."
  make DESTDIR="${ADM_DESTDIR}" install

  # Por padrão, com --enable-widec, as libs principais são libncursesw.*.
  # Alguns softwares ainda esperam 'ncurses' em vez de 'ncursesw'. Aqui criamos
  # alguns symlinks de compatibilidade básicos.
  local real_libdir="${ADM_DESTDIR%/}${libdir}"
  if [ -d "$real_libdir" ]; then
    log "Criando symlinks de compatibilidade para ncursesw (se necessário)..."
    (
      cd "$real_libdir" || exit 0
      if [ -e "libncursesw.so" ] && [ ! -e "libncurses.so" ]; then
        ln -svf libncursesw.so libncurses.so || true
      fi
      if [ -e "libncursesw.a" ] && [ ! -e "libncurses.a" ]; then
        ln -svf libncursesw.a libncurses.a || true
      fi

      # libcurses compat
      if [ -e "libncursesw.so" ] && [ ! -e "libcursesw.so" ]; then
        ln -svf libncursesw.so libcursesw.so || true
      fi
      if [ -e "libncurses.so" ] && [ ! -e "libcurses.so" ]; then
        ln -svf libncurses.so libcurses.so || true
      fi
    )
  else
    log "Aviso: libdir real não encontrado para symlinks: ${real_libdir}"
  fi

  # Informar versão ao adm
  export PKG_VERSION="$NCURSES_VERSION"

  log "Ncurses ${NCURSES_VERSION} instalado em ${ADM_DESTDIR}${prefix} (para empacotamento pelo adm)."
}

clean_ncurses() {
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
      # $2 é a libc passada pelo adm; aqui é usada apenas para logging
      shift || true
      build_ncurses
      ;;

    clean)
      clean_ncurses
      ;;

    *)
      cat <<EOF
Uso: $(basename "$0") <ação> [libc]

Ações suportadas:
  download   - baixa o tarball do ncurses (${TARBALL}) para o cache
  build      - compila e instala o ncurses em ADM_DESTDIR (para empacotamento)
  clean      - remove o diretório de build (ADM_BUILD_ROOT)

Exemplo com o adm:
  adm build ${ADM_CATEGORY:-core}/${ADM_PKG_NAME:-ncurses} glibc
  adm install ${ADM_CATEGORY:-core}/${ADM_PKG_NAME:-ncurses} glibc

Variáveis de ajuste (opcionais):
  ADM_NCURSES_TARBALL_URL   - URL alternativa do tarball
  ADM_NCURSES_BUILD_TRIPLET - triplet de build (default: \$(gcc -dumpmachine))
  ADM_NCURSES_HOST_TRIPLET  - host triplet (default: igual ao build)
  ADM_NCURSES_PREFIX        - prefix (default: /usr)
  ADM_NCURSES_LIBDIR        - libdir (default: \${ADM_NCURSES_PREFIX}/lib)
  ADM_NCURSES_ENABLE_NLS    - se "1", não passa --disable-nls
  ADM_NCURSES_WITH_ADA      - se "1", tenta habilitar suporte a Ada
  ADM_NCURSES_EXTRA_CONFIG  - opções extras para o configure
  ADM_NCURSES_RUN_TESTS     - se "1", tenta 'make check'
  ADM_MAKE_JOBS             - número de jobs no make (default: nproc ou 1)

EOF
      ;;
  esac
}

main "$@"
