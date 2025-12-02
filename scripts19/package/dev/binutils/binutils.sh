#!/usr/bin/env bash
# Script de construção do Binutils para o adm
# Caminho esperado:
#   /mnt/adm/packages/dev/binutils/binutils.sh
#
# O adm fornece:
#   - SRC_DIR  : diretório com o source extraído
#   - DESTDIR  : raiz de instalação temporária (pkgroot)
#   - PROFILE  : glibc / musl / outro (string)
#   - NUMJOBS  : número de jobs para o make
#
# Este script deve definir:
#   - PKG_VERSION
#   - SRC_URL
#   - (opcional) SRC_MD5
#   - função pkg_build()

# Versão e source oficial
PKG_VERSION="2.45.1"
SRC_URL="https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
# Se quiser verificar integridade via MD5, defina aqui:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [binutils] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS : ${NUMJOBS:-1}"

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção básica de arquitetura
  #------------------------------------
  local ARCH SLKCFLAGS LIBDIRSUFFIX WERROR
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i586
      SLKCFLAGS="-O2 -march=pentium4 -mtune=generic"
      LIBDIRSUFFIX=""
      # werror = off em 32 bits para evitar build quebrar com warnings
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

  # TARGET (triplet de build)
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
  #------------------------------------
  local EXTRA_CONFIG_FLAGS=""
  case "${PROFILE:-}" in
    musl)
      echo "==> [binutils] Ajustes para musl (exemplo: desativar nls se necessário)"
      # Se quiser algo específico pra musl, coloque aqui:
      # EXTRA_CONFIG_FLAGS+=" --disable-nls"
      ;;
    glibc|"")
      echo "==> [binutils] Usando configuração padrão para glibc"
      ;;
    *)
      echo "==> [binutils] PROFILE desconhecido: ${PROFILE}, seguindo configuração padrão"
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

  # 1) Remover libtool .la se você não quiser espalhar .la
  if command -v find >/dev/null 2>&1; then
    echo "==> [binutils] Removendo arquivos .la desnecessários"
    find "$DESTDIR/usr/lib${LIBDIRSUFFIX}" -name '*.la' -type f -print0 2>/dev/null \
      | xargs -0r rm -f
  fi

  # 2) Strip de binários (sem falhar se strip não suportar algo)
  if command -v strip >/dev/null 2>&1; then
    echo "==> [binutils] strip de binários"
    # ELF executáveis
    find "$DESTDIR" -type f -perm -0100 2>/dev/null \
      -exec sh -c 'file -bi "$1" | grep -q "x-executable" && strip --strip-unneeded "$1" || true' _ {} \;
    # Bibliotecas compartilhadas
    find "$DESTDIR" -type f -name '*.so*' 2>/dev/null \
      -exec sh -c 'file -bi "$1" | grep -q "x-sharedlib" && strip --strip-unneeded "$1" || true' _ {} \;
  else
    echo "==> [binutils] strip não encontrado; pulando etapa de strip"
  fi

  # 3) Compactar manpages
  if command -v gzip >/dev/null 2>&1; then
    echo "==> [binutils] Compactando manpages"
    if [ -d "$DESTDIR/usr/man" ]; then
      find "$DESTDIR/usr/man" -type f -name '*.[0-9]' -print0 2>/dev/null \
        | xargs -0r gzip -9
    fi
    if [ -d "$DESTDIR/usr/info" ]; then
      # Muitos sistemas ainda usam info não comprimido; ajuste se quiser
      :
    fi
  fi

  echo "==> [binutils] Build do binutils-${PKG_VERSION} finalizado com sucesso."
}
