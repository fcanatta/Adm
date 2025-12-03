#!/usr/bin/env bash
# Script de construção do MPC para o adm
# Caminho: /mnt/adm/packages/libs/mpc/mpc.sh

PKG_VERSION="1.3.1"
SRC_URL="https://ftp.gnu.org/gnu/mpc/mpc-${PKG_VERSION}.tar.gz"

pkg_build() {
  set -euo pipefail

  echo "==> [mpc] Build iniciado"
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

  echo "==> [mpc] ARCH   : $ARCH"
  echo "==> [mpc] CFLAGS : $SLKCFLAGS"
  echo "==> [mpc] LIBDIR : /usr/lib${LIBDIRSUFFIX}"

  local EXTRA_CONFIG_FLAGS=""
  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [mpc] Ajustes para GLIBC"
      ;;
    musl)
      echo "==> [mpc] Ajustes para MUSL"
      ;;
    *)
      echo "==> [mpc] PROFILE desconhecido (${PROFILE}), sem flags extras"
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
    --docdir=/usr/share/doc/mpc-${PKG_VERSION} \
    $EXTRA_CONFIG_FLAGS

  echo "==> [mpc] configure concluído"

  make -j"${NUMJOBS:-1}"
  echo "==> [mpc] make concluído"

  # Testes opcionais:
  # make check || true

  make DESTDIR="$DESTDIR" install
  echo "==> [mpc] make install concluído em $DESTDIR"

  if command -v find >/dev/null 2>&1; then
    if [ -d "$DESTDIR/usr/lib${LIBDIRSUFFIX}" ]; then
      echo "==> [mpc] Removendo arquivos .la"
      find "$DESTDIR/usr/lib${LIBDIRSUFFIX}" -name '*.la' -type f -print0 2>/dev/null \
        | xargs -0r rm -f
    fi
  fi

  echo "==> [mpc] Build do mpc-${PKG_VERSION} finalizado."
}
