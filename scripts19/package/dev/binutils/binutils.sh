#!/usr/bin/env bash
# Script de construção do Binutils para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/dev/binutils/binutils.sh
#
# O adm fornece as variáveis:
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
PKG_VERSION="2.45.1"
SRC_URL="https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
# Se quiser verificar integridade via MD5, preencha:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  # fail fast dentro do build
  set -euo pipefail

  echo "==> [binutils] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS : ${NUMJOBS:-1}"

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e flags
  #------------------------------------
  local ARCH SLKCFLAGS LIBDIRSUFFIX WERROR
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i586
      SLKCFLAGS="-O2 -march=pentium4 -mtune=generic"
      LIBDIRSUFFIX=""
      # em 32 bits, evitar que warnings virem erro
      WERROR="--enable-werror=no"
      ;;
    x86_64)
      SLKCFLAGS="-O2 -march=x86-64 -mtune=generic -fPIC"
      LIBDIRSUFFIX="64"
      WERROR=""
      ;;
    *)
      SLKCFLAGS="-O2"
      LIBDIRSUFFIX=""
      WERROR=""
      ;;
  esac

  # TARGET (triplet) – tenta usar o próprio GCC
  local TARGET
  if command -v gcc >/dev/null 2>&1; then
    TARGET="$(gcc -dumpmachine)"
  else
    TARGET="${ARCH}-pc-linux-gnu"
  fi

  echo "==> [binutils] ARCH   : $ARCH"
  echo "==> [binutils] TARGET : $TARGET"
  echo "==> [binutils] CFLAGS : $SLKCFLAGS"
  echo "==> [binutils] LIBDIR : /usr/lib${LIBDIRSUFFIX}"

  #------------------------------------
  # Ajustes específicos por PROFILE
  #   EXTRA_CONFIG_FLAGS vai pro ./configure
  #------------------------------------
  local EXTRA_CONFIG_FLAGS=""
  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [binutils] Ajustes de configure para GLIBC"

      # Ativa NLS (traduções) – requer gettext/libintl em tempo de build
      EXTRA_CONFIG_FLAGS+=" --enable-nls"

      # Usa zlib do sistema (recomendado)
      EXTRA_CONFIG_FLAGS+=" --with-system-zlib"

      # Garante ar/ranlib determinísticos
      EXTRA_CONFIG_FLAGS+=" --enable-deterministic-archives"

      # Se tiver problema com gprofng ou não quiser:
      # EXTRA_CONFIG_FLAGS+=" --disable-gprofng"

      # Se quiser o linker gold junto com ld.bfd:
      # EXTRA_CONFIG_FLAGS+=" --enable-gold"
      ;;

    musl)
      echo "==> [binutils] Ajustes de configure para MUSL"

      # Em musl é comum desabilitar NLS
      EXTRA_CONFIG_FLAGS+=" --disable-nls"

      # Usa zlib do sistema (se você tiver zlib para musl)
      EXTRA_CONFIG_FLAGS+=" --with-system-zlib"

      # Deterministic archives também aqui
      EXTRA_CONFIG_FLAGS+=" --enable-deterministic-archives"

      # gprofng costuma dar mais trabalho fora de glibc
      EXTRA_CONFIG_FLAGS+=" --disable-gprofng"

      # Se rolar problema com werror extra:
      # EXTRA_CONFIG_FLAGS+=" --disable-werror"
      ;;

    *)
      echo "==> [binutils] PROFILE desconhecido (${PROFILE}), sem flags extras específicas"
      ;;
  esac

  #------------------------------------
  # Diretório de build separado
  #------------------------------------
  local BUILD_DIR
  BUILD_DIR="$SRC_DIR/build"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"

  #------------------------------------
  # Configure
  #------------------------------------
  CFLAGS="$SLKCFLAGS" \
  "$SRC_DIR/configure" \
    --prefix=/usr \
    --libdir=/usr/lib${LIBDIRSUFFIX} \
    --sysconfdir=/etc \
    --mandir=/usr/man \
    --infodir=/usr/info \
    --disable-compressed-debug-sections \
    --enable-shared \
    --enable-multilib \
    --enable-64-bit-bfd \
    --enable-plugins \
    --enable-threads \
    --enable-targets=i386-efi-pe,bpf-unknown-none,${TARGET} \
    --enable-install-libiberty \
    --enable-ld=default \
    --enable-initfini-array \
    $WERROR \
    --build="$TARGET" \
    $EXTRA_CONFIG_FLAGS

  echo "==> [binutils] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  make -j"${NUMJOBS:-1}"
  echo "==> [binutils] make concluído"

  #------------------------------------
  # Instalação em DESTDIR
  #------------------------------------
  make DESTDIR="$DESTDIR" install
  echo "==> [binutils] make install concluído em $DESTDIR"

  #------------------------------------
  # Pós-instalação em DESTDIR (limpezas)
  #------------------------------------

  # 1) Remover .la (se existir)
  if command -v find >/dev/null 2>&1; then
    if [ -d "$DESTDIR/usr/lib${LIBDIRSUFFIX}" ]; then
      echo "==> [binutils] Removendo arquivos .la desnecessários"
      find "$DESTDIR/usr/lib${LIBDIRSUFFIX}" -name '*.la' -type f -print0 2>/dev/null \
        | xargs -0r rm -f
    fi
  fi

  # 2) Strip de binários e libs (sem abortar se strip não suportar algo)
  if command -v strip >/dev/null 2>&1 && command -v file >/dev/null 2>&1; then
    echo "==> [binutils] strip de binários e bibliotecas"

    # ELF executáveis
    find "$DESTDIR" -type f -perm -0100 2>/dev/null \
      | while IFS= read -r f; do
          if file -bi "$f" 2>/dev/null | grep -q "x-executable"; then
            strip --strip-unneeded "$f" 2>/dev/null || true
          fi
        done

    # Bibliotecas compartilhadas
    find "$DESTDIR" -type f -name '*.so*' 2>/dev/null \
      | while IFS= read -r f; do
          if file -bi "$f" 2>/dev/null | grep -q "x-sharedlib"; then
            strip --strip-unneeded "$f" 2>/dev/null || true
          fi
        done
  else
    echo "==> [binutils] strip ou file não encontrados; pulando etapa de strip"
  fi

  # 3) Compactar manpages
  if command -v gzip >/dev/null 2>&1; then
    if [ -d "$DESTDIR/usr/man" ]; then
      echo "==> [binutils] Compactando manpages"
      find "$DESTDIR/usr/man" -type f -name '*.[0-9]' -print0 2>/dev/null \
        | xargs -0r gzip -9
    fi
  fi

  echo "==> [binutils] Build do binutils-${PKG_VERSION} finalizado com sucesso."
}
