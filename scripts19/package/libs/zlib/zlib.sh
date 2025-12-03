#!/usr/bin/env bash
# Script de construção do zlib para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/libs/zlib/zlib.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball
#   DESTDIR  : raiz de instalação temporária (pkgroot)
#   PROFILE  : glibc / musl / outro (string)
#   NUMJOBS  : número de jobs para o make
#
# Este script deve definir:
#   PKG_VERSION
#   SRC_URL
#   (opcional) SRC_MD5
#   função pkg_build()

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="1.3.1"
SRC_URL="https://zlib.net/zlib-${PKG_VERSION}.tar.xz"
# Se quiser verificar integridade, pode pegar o checksum oficial e setar:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [zlib] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS : ${NUMJOBS:-1}"

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e flags
  #------------------------------------
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

  echo "==> [zlib] ARCH   : $ARCH"
  echo "==> [zlib] CFLAGS : $SLKCFLAGS"
  echo "==> [zlib] LIBDIR : /usr/lib${LIBDIRSUFFIX}"

  #------------------------------------
  # Ajustes por PROFILE (apenas informativo)
  #------------------------------------
  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [zlib] PROFILE = glibc (ou vazio) – build padrão"
      ;;
    musl)
      echo "==> [zlib] PROFILE = musl – build compatível com musl (sem ajustes especiais)."
      ;;
    *)
      echo "==> [zlib] PROFILE desconhecido (${PROFILE}), seguindo build padrão."
      ;;
  esac

  #------------------------------------
  # Diretório de build (zlib até deixa usar o próprio source,
  # mas sigo padrão com subdir build pra manter consistência)
  #------------------------------------
  local BUILD_DIR
  BUILD_DIR="$SRC_DIR/build"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"

  #------------------------------------
  # Configure
  #
  # zlib usa ./configure próprio (não o autoconf padrão).
  #  - --prefix=/usr
  #  - --libdir=/usr/lib${LIBDIRSUFFIX}
  #  - --shared  (somente libs .so; vamos remover .a depois se aparecerem)
  #------------------------------------
  CFLAGS="$SLKCFLAGS" \
  "$SRC_DIR/configure" \
    --prefix=/usr \
    --libdir=/usr/lib${LIBDIRSUFFIX} \
    --shared

  echo "==> [zlib] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  make -j"${NUMJOBS:-1}"
  echo "==> [zlib] make concluído"

  # Testes opcionais:
  #   make check || true

  #------------------------------------
  # Instalação em DESTDIR
  #------------------------------------
  make DESTDIR="$DESTDIR" install
  echo "==> [zlib] make install concluído em $DESTDIR"

  #------------------------------------
  # Pós-instalação: limpeza de static / .la e strip
  #------------------------------------
  local LIBDIR_PATH="$DESTDIR/usr/lib${LIBDIRSUFFIX}"

  # Remover libs estáticas (.a), se houver
  if [ -d "$LIBDIR_PATH" ]; then
    echo "==> [zlib] Removendo libs estáticas (.a) em $LIBDIR_PATH"
    find "$LIBDIR_PATH" -maxdepth 1 -type f -name 'libz.a' -print0 2>/dev/null \
      | xargs -0r rm -f

    echo "==> [zlib] Removendo arquivos .la em $LIBDIR_PATH (se existirem)"
    find "$LIBDIR_PATH" -maxdepth 1 -type f -name '*.la' -print0 2>/dev/null \
      | xargs -0r rm -f
  fi

  # Strip das libs compartilhadas
  if command -v strip >/dev/null 2>&1 && command -v file >/dev/null 2>&1; then
    echo "==> [zlib] strip de bibliotecas compartilhadas"
    find "$LIBDIR_PATH" -maxdepth 1 -type f -name 'libz.so*' 2>/dev/null \
      | while IFS= read -r f; do
          if file -bi "$f" 2>/dev/null | grep -q "x-sharedlib"; then
            strip --strip-unneeded "$f" 2>/dev/null || true
          fi
        done
  fi

  echo "==> [zlib] Build do zlib-${PKG_VERSION} finalizado com sucesso."
}
