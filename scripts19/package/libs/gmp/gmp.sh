#!/usr/bin/env bash
# Script de construção do GMP para o adm
# Caminho: /mnt/adm/packages/libs/gmp/gmp.sh

PKG_VERSION="6.3.0"
SRC_URL="https://ftp.gnu.org/gnu/gmp/gmp-${PKG_VERSION}.tar.bz2"
# Opcional:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [gmp] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS : ${NUMJOBS:-1}"

  cd "$SRC_DIR"

  # Arquitetura e flags
  local ARCH SLKCFLAGS LIBDIRSUFFIX
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i586
      SLKCFLAGS="-O2 -march=pentium4 -mtune=generic"
      LIBDIRSUFFIX=""
      ;;
    x86_64)
      SLKCFLAGS="-O2 -march=x86-64 -mtune=generic -fPIC"
      LIBDIRSUFFIX="64"
      ;;
    *)
      SLKCFLAGS="-O2"
      LIBDIRSUFFIX=""
      ;;
  esac

  echo "==> [gmp] ARCH   : $ARCH"
  echo "==> [gmp] CFLAGS : $SLKCFLAGS"
  echo "==> [gmp] LIBDIR : /usr/lib${LIBDIRSUFFIX}"

  # Ajustes por profile (se quiser algo específico)
  local EXTRA_CONFIG_FLAGS=""
  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [gmp] Ajustes para GLIBC"
      # Se quiser libs mais genéricas (não otimizadas por CPU), pode usar:
      # EXTRA_CONFIG_FLAGS+=" --host=none-linux-gnu"
      ;;
    musl)
      echo "==> [gmp] Ajustes para MUSL"
      # Se tiver problema com detecção de CPU:
      # EXTRA_CONFIG_FLAGS+=" --host=none-linux-musl"
      ;;
    *)
      echo "==> [gmp] PROFILE desconhecido (${PROFILE}), sem flags extras"
      ;;
  esac

  # Diretório de build (GMP pode ser feito direto, mas separo pra ficar padrão)
  local BUILD_DIR
  BUILD_DIR="$SRC_DIR/build"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"

  CFLAGS="$SLKCFLAGS" \
  "$SRC_DIR/configure" \
    --prefix=/usr \
    --libdir=/usr/lib${LIBDIRSUFFIX} \
    --enable-cxx \
    --disable-static \
    --docdir=/usr/share/doc/gmp-${PKG_VERSION} \
    $EXTRA_CONFIG_FLAGS

  echo "==> [gmp] configure concluído"

  make -j"${NUMJOBS:-1}"
  echo "==> [gmp] make concluído"

  # Testes (opcional, mas recomendados)
  # make check 2>&1 | tee gmp-check.log || true

  make DESTDIR="$DESTDIR" install
  echo "==> [gmp] make install concluído em $DESTDIR"

  # Não removo .a porque já desabilitei static via configure.
  # Se quiser, pode limpar .la:
  if command -v find >/dev/null 2>&1; then
    if [ -d "$DESTDIR/usr/lib${LIBDIRSUFFIX}" ]; then
      echo "==> [gmp] Removendo arquivos .la"
      find "$DESTDIR/usr/lib${LIBDIRSUFFIX}" -name '*.la' -type f -print0 2>/dev/null \
        | xargs -0r rm -f
    fi
  fi

  echo "==> [gmp] Build do gmp-${PKG_VERSION} finalizado."
}
