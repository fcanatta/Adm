#!/usr/bin/env bash
# Script de construção do pacote: Linux 6.17.9 API Headers
#
# Este script é chamado pelo adm assim:
#   bash linux-headers.sh build <libc>
#
# Variáveis importantes exportadas pelo adm:
#   ADM_CATEGORY     - categoria do pacote (ex: "linux")
#   ADM_PKG_NAME     - nome do pacote (ex: "linux-headers")
#   ADM_LIBC         - libc alvo ("glibc" ou "musl")
#   ADM_ROOTFS       - rootfs de destino (não usamos diretamente aqui)
#   ADM_CACHE_SRC    - cache de fontes (ex: /var/cache/adm/sources)
#   ADM_CACHE_PKG    - cache de pacotes (tarballs prontos)
#   ADM_BUILD_ROOT   - diretório de build temporário
#   ADM_DESTDIR      - DESTDIR usado para empacotar (virará / dentro do rootfs)
#
# Este script instala os headers em:
#   ${ADM_DESTDIR}/usr/include
#
# Versão do kernel: 6.17.9

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

KERNEL_VERSION="6.17.9"
KERNEL_NAME="linux-${KERNEL_VERSION}"

: "${ADM_CACHE_SRC:=/var/cache/adm/sources}"
: "${ADM_BUILD_ROOT:=/tmp/adm-build-${ADM_CATEGORY:-linux}-${ADM_PKG_NAME:-linux-headers}-${ADM_LIBC:-glibc}}"
: "${ADM_DESTDIR:=${ADM_BUILD_ROOT}/destdir}"

# URL padrão do tarball do kernel (ajustável via ADM_LINUX_SRC_URL se quiser outro mirror)
KERNEL_TARBALL="${KERNEL_NAME}.tar.xz"
KERNEL_URL_DEFAULT="https://cdn.kernel.org/pub/linux/kernel/v6.x/${KERNEL_TARBALL}"
KERNEL_URL="${ADM_LINUX_SRC_URL:-$KERNEL_URL_DEFAULT}"

SRC_ARCHIVE="${ADM_CACHE_SRC}/${KERNEL_TARBALL}"
SRC_DIR="${ADM_BUILD_ROOT}/${KERNEL_NAME}"

# Arquitetura alvo dos headers (pode sobrescrever via ADM_KERNEL_ARCH, senão usa uname -m)
KERNEL_ARCH="${ADM_KERNEL_ARCH:-$(uname -m)}"

###############################################################################
# FUNÇÕES AUXILIARES
###############################################################################

log() {
  printf '[linux-headers] %s\n' "$*"
}

die() {
  printf '[linux-headers][ERRO] %s\n' "$*" >&2
  exit 1
}

ensure_tools() {
  local missing=()
  for cmd in tar make; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  # Não é obrigatório, mas tentamos ter pelo menos curl ou wget para baixar.
  if [ ! -f "$SRC_ARCHIVE" ]; then
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
      missing+=("curl/wget")
    end
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

  log "Baixando kernel headers ${KERNEL_VERSION} de: $KERNEL_URL"
  if command -v curl >/dev/null 2>&1; then
    curl -L -o "$SRC_ARCHIVE" "$KERNEL_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$SRC_ARCHIVE" "$KERNEL_URL"
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

build_headers() {
  mkdir -p "$ADM_DESTDIR/usr"

  log "Entrando no diretório de fontes: $SRC_DIR"
  cd "$SRC_DIR"

  log "Limpando árvore (make mrproper) para garantir build reprodutível"
  make ARCH="${KERNEL_ARCH}" mrproper

  log "Gerando headers (make headers)"
  make ARCH="${KERNEL_ARCH}" headers

  log "Instalando headers em DESTDIR=${ADM_DESTDIR}/usr (make headers_install)"
  make ARCH="${KERNEL_ARCH}" headers_install INSTALL_HDR_PATH="${ADM_DESTDIR}/usr"

  # Ajustes finais opcionais: remover arquivos desnecessários dentro do DESTDIR,
  # se você quiser ser mais agressivo. Em geral, headers_install já limpa bem.
  #
  # Exemplo (descomentando se quiser):
  # find "${ADM_DESTDIR}/usr/include" -name '.*' -delete || true

  # Informa a versão ao adm (usada em adm_finalize_build para PKG_VERSION)
  export PKG_VERSION="$KERNEL_VERSION"

  log "Headers do Linux ${KERNEL_VERSION} instalados em ${ADM_DESTDIR}/usr/include"
}

clean_build() {
  log "Limpando build root: $ADM_BUILD_ROOT"
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
      # $2 é a libc, mas não precisamos usar diretamente aqui; o adm já
      # separa o pacote por libc e usa DESTDIR diferente.
      shift || true

      ensure_tools
      fetch_source
      extract_source
      build_headers
      ;;

    clean)
      clean_build
      ;;

    *)
      cat <<EOF
Uso: $(basename "$0") <ação> [libc]

Ações suportadas:
  download   - apenas baixa o tarball do kernel (${KERNEL_TARBALL}) para o cache
  build      - constrói e instala os API headers em ADM_DESTDIR/usr/include
  clean      - remove o diretório de build (ADM_BUILD_ROOT)

Este script é normalmente chamado pelo 'adm' com:
  adm build ${ADM_CATEGORY:-linux}/${ADM_PKG_NAME:-linux-headers} [libc]

EOF
      ;;
  esac
}

main "$@"
