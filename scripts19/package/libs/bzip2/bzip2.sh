#!/usr/bin/env bash
# Script de construção do Bzip2 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/libs/bzip2/bzip2.sh
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
PKG_VERSION="1.0.8"
SRC_URL="https://sourceware.org/pub/bzip2/bzip2-${PKG_VERSION}.tar.gz"
# Se quiser, pode definir MD5:
# SRC_MD5="67e051268d0c475ea773822f7500d0e5"

pkg_build() {
  set -euo pipefail

  echo "==> [bzip2] Build iniciado"
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

  echo "==> [bzip2] ARCH   : $ARCH"
  echo "==> [bzip2] CFLAGS : $SLKCFLAGS"
  echo "==> [bzip2] LIBDIR : /usr/lib${LIBDIRSUFFIX}"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [bzip2] PROFILE = glibc (ou vazio) – build padrão"
      ;;
    musl)
      echo "==> [bzip2] PROFILE = musl – build compatível com musl (sem ajustes especiais)"
      ;;
    *)
      echo "==> [bzip2] PROFILE desconhecido (${PROFILE}), apenas log"
      ;;
  esac

  #------------------------------------
  # Aplicar patch de soname + shared (estilo LFS/BLFS, opcional)
  #
  # Isso substitui o Makefile pra gerar libbz2.so com soname
  # decente e links corretos.
  # Se não quiser mexer, pode comentar esse bloco.
  #------------------------------------
  if [ -f "Makefile-libbz2_so" ]; then
    echo "==> [bzip2] Ajustando Makefile para libs compartilhadas"
    sed -i 's/^all:.*$/all: libbz2.a bzip2 bzip2recover test/' Makefile
  fi

  #------------------------------------
  # Compilar
  #
  # O Makefile do bzip2 não usa ./configure; é só make.
  # Vamos compilar a lib estática e o binário, depois
  # gerar lib compartilhada com "make -f Makefile-libbz2_so".
  #------------------------------------
  echo "==> [bzip2] Compilando (lib estática + binários)"
  make -j"${NUMJOBS:-1}" CFLAGS="$SLKCFLAGS"

  if [ -f "Makefile-libbz2_so" ]; then
    echo "==> [bzip2] Compilando libbz2.so (Makefile-libbz2_so)"
    make -f Makefile-libbz2_so CFLAGS="$SLKCFLAGS"
  fi

  #------------------------------------
  # Instalar em DESTDIR
  #------------------------------------
  local BIN_DIR="$DESTDIR/usr/bin"
  local LIB_DIR="$DESTDIR/usr/lib${LIBDIRSUFFIX}"
  local INC_DIR="$DESTDIR/usr/include"
  local MAN_DIR="$DESTDIR/usr/share/man"

  mkdir -p "$BIN_DIR" "$LIB_DIR" "$INC_DIR" "$MAN_DIR/man1"

  echo "==> [bzip2] Instalando binários em $BIN_DIR"
  install -m 0755 bzip2   "$BIN_DIR/bzip2"
  install -m 0755 bzip2recover "$BIN_DIR/bzip2recover"
  install -m 0755 bzgrep  "$BIN_DIR/bzgrep"
  install -m 0755 bzmore  "$BIN_DIR/bzmore"
  install -m 0755 bzless  "$BIN_DIR/bzless"
  install -m 0755 bzdiff  "$BIN_DIR/bzdiff"

  # links compatíveis (bzip2/bunzip2/bzcat, etc.)
  ln -sf bzip2 "$BIN_DIR/bunzip2"
  ln -sf bzip2 "$BIN_DIR/bzcat"
  ln -sf bzgrep "$BIN_DIR/bzegrep"
  ln -sf bzgrep "$BIN_DIR/bzfgrep"
  ln -sf bzdiff "$BIN_DIR/bzcmp"
  ln -sf bzdiff "$BIN_DIR/bzcmp"

  echo "==> [bzip2] Instalando headers em $INC_DIR"
  install -m 0644 bzlib.h "$INC_DIR/"

  echo "==> [bzip2] Instalando manpages em $MAN_DIR/man1"
  install -m 0644 bzip2.1 "$MAN_DIR/man1/"
  ln -sf bzip2.1 "$MAN_DIR/man1/bunzip2.1"
  ln -sf bzip2.1 "$MAN_DIR/man1/bzcat.1"
  install -m 0644 bzgrep.1 "$MAN_DIR/man1/"
  ln -sf bzgrep.1 "$MAN_DIR/man1/bzegrep.1"
  ln -sf bzgrep.1 "$MAN_DIR/man1/bzfgrep.1"
  install -m 0644 bzdiff.1 "$MAN_DIR/man1/"
  ln -sf bzdiff.1 "$MAN_DIR/man1/bzcmp.1"
  install -m 0644 bzmore.1 "$MAN_DIR/man1/"
  ln -sf bzmore.1 "$MAN_DIR/man1/bzless.1"

  #------------------------------------
  # Instalar libs
  #------------------------------------
  echo "==> [bzip2] Instalando libs em $LIB_DIR"

  # Lib estática (vamos instalar e depois remover se você quiser só shared)
  if [ -f "libbz2.a" ]; then
    install -m 0644 libbz2.a "$LIB_DIR/"
  fi

  # Lib compartilhada
  if [ -f "libbz2.so.${PKG_VERSION}" ]; then
    install -m 0755 "libbz2.so.${PKG_VERSION}" "$LIB_DIR/"
    ( cd "$LIB_DIR"
      ln -sf "libbz2.so.${PKG_VERSION}" "libbz2.so.1.0"
      ln -sf "libbz2.so.1.0" "libbz2.so"
    )
  elif [ -f "libbz2.so.1.0.8" ]; then
    # Nome usado pelo Makefile-libbz2_so de alguns distros
    install -m 0755 libbz2.so.1.0.8 "$LIB_DIR/"
    ( cd "$LIB_DIR"
      ln -sf "libbz2.so.1.0.8" "libbz2.so.1.0"
      ln -sf "libbz2.so.1.0" "libbz2.so"
    )
  fi

  #------------------------------------
  # Limpeza: remover .a / .la se não quiser libs estáticas
  #------------------------------------
  if [ -d "$LIB_DIR" ]; then
    echo "==> [bzip2] Removendo libbz2.a (se não quiser lib estática)"
    find "$LIB_DIR" -maxdepth 1 -type f -name 'libbz2.a' -print0 2>/dev/null \
      | xargs -0r rm -f

    echo "==> [bzip2] Removendo .la (se existirem)"
    find "$LIB_DIR" -maxdepth 1 -type f -name '*.la' -print0 2>/dev/null \
      | xargs -0r rm -f
  fi

  #------------------------------------
  # Strip de lib / bin
  #------------------------------------
  if command -v strip >/dev/null 2>&1 && command -v file >/dev/null 2>&1; then
    echo "==> [bzip2] strip de binários e libs"

    # Binários
    find "$BIN_DIR" -type f -perm -0100 2>/dev/null \
      | while IFS= read -r f; do
          if file -bi "$f" 2>/dev/null | grep -q "x-executable"; then
            strip --strip-unneeded "$f" 2>/dev/null || true
          fi
        done

    # Bibliotecas compartilhadas
    find "$LIB_DIR" -type f -name 'libbz2.so*' 2>/dev/null \
      | while IFS= read -r f; do
          if file -bi "$f" 2>/dev/null | grep -q "x-sharedlib"; then
            strip --strip-unneeded "$f" 2>/dev/null || true
          fi
        done
  fi

  echo "==> [bzip2] Build do bzip2-${PKG_VERSION} finalizado com sucesso."
}
