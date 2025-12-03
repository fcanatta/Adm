#!/usr/bin/env bash
# Script de construção do MPFR para o adm
# Caminho: /mnt/adm/packages/libs/mpfr/mpfr.sh

PKG_VERSION="4.2.1"
SRC_URL="https://ftp.gnu.org/gnu/mpfr/mpfr-${PKG_VERSION}.tar.xz"

pkg_build() {
  set -euo pipefail

  echo "==> [mpfr] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS : ${NUMJOBS:-1}"

  cd "$SRC_DIR"

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

  echo "==> [mpfr] ARCH   : $ARCH"
  echo "==> [mpfr] CFLAGS : $SLKCFLAGS"
  echo "==> [mpfr] LIBDIR : /usr/lib${LIBDIRSUFFIX}"

  local EXTRA_CONFIG_FLAGS=""
  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [mpfr] Ajustes para GLIBC"
      EXTRA_CONFIG_FLAGS+=" --enable-thread-safe"
      ;;
    musl)
      echo "==> [mpfr] Ajustes para MUSL"
      EXTRA_CONFIG_FLAGS+=" --enable-thread-safe"
      ;;
    *)
      echo "==> [mpfr] PROFILE desconhecido (${PROFILE}), sem flags extras"
      ;;
  esac

  local BUILD_DIR
  BUILD_DIR="$SRC_DIR/build"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"

  CFLAGS="$SLKCFLAGS" \
  "$SRC_DIR/configure" \
    --prefix=/usr \
    --libdir=/usr/lib${LIBDIRSUFFIX} \
    --disable-static \
    --docdir=/usr/share/doc/mpfr-${PKG_VERSION} \
    $EXTRA_CONFIG_FLAGS

  echo "==> [mpfr] configure concluído"

  make -j"${NUMJOBS:-1}"
  echo "==> [mpfr] make concluído"

  # Testes opcionais:
  # make check || true

  make DESTDIR="$DESTDIR" install
  echo "==> [mpfr] make install concluído em $DESTDIR"

  if command -v find >/dev/null 2>&1; then
    if [ -d "$DESTDIR/usr/lib${LIBDIRSUFFIX}" ]; then
      echo "==> [mpfr] Removendo arquivos .la"
      find "$DESTDIR/usr/lib${LIBDIRSUFFIX}" -name '*.la' -type f -print0 2>/dev/null \
        | xargs -0r rm -f
    fi
  fi

  echo "==> [mpfr] Build do mpfr-${PKG_VERSION} finalizado."
}
