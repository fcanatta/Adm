#!/usr/bin/env bash
# Script de construção do ISL para o adm
# Caminho: /mnt/adm/packages/libs/isl/isl.sh

PKG_VERSION="0.27"
SRC_URL="https://sourceforge.net/projects/libisl/files/isl-${PKG_VERSION}.tar.xz/download"

pkg_build() {
  set -euo pipefail

  echo "==> [isl] Build iniciado"
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

  echo "==> [isl] ARCH   : $ARCH"
  echo "==> [isl] CFLAGS : $SLKCFLAGS"
  echo "==> [isl] LIBDIR : /usr/lib${LIBDIRSUFFIX}"

  local EXTRA_CONFIG_FLAGS=""
  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [isl] Ajustes para GLIBC"
      ;;
    musl)
      echo "==> [isl] Ajustes para MUSL"
      ;;
    *)
      echo "==> [isl] PROFILE desconhecido (${PROFILE}), sem flags extras"
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
    --docdir=/usr/share/doc/isl-${PKG_VERSION} \
    $EXTRA_CONFIG_FLAGS

  echo "==> [isl] configure concluído"

  make -j"${NUMJOBS:-1}"
  echo "==> [isl] make concluído"

  make DESTDIR="$DESTDIR" install
  echo "==> [isl] make install concluído em $DESTDIR"

  # Mover script de auto-load do gdb para local correto dentro do DESTDIR
  local gdb_autoload_dir="$DESTDIR/usr/share/gdb/auto-load/usr/lib${LIBDIRSUFFIX}"
  mkdir -p "$gdb_autoload_dir"

  if [ -d "$DESTDIR/usr/lib${LIBDIRSUFFIX}" ]; then
    find "$DESTDIR/usr/lib${LIBDIRSUFFIX}" -maxdepth 1 -name 'libisl*py' -type f 2>/dev/null \
      | while IFS= read -r f; do
          echo "==> [isl] Movendo $(basename "$f") para auto-load do gdb"
          mv -v "$f" "$gdb_autoload_dir"/
        done
  fi

  # Limpar .la se existir
  if command -v find >/dev/null 2>&1; then
    if [ -d "$DESTDIR/usr/lib${LIBDIRSUFFIX}" ]; then
      echo "==> [isl] Removendo arquivos .la"
      find "$DESTDIR/usr/lib${LIBDIRSUFFIX}" -name '*.la' -type f -print0 2>/dev/null \
        | xargs -0r rm -f
    fi
  fi

  echo "==> [isl] Build do isl-${PKG_VERSION} finalizado."
}
