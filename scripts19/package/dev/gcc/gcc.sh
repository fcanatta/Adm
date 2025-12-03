#!/usr/bin/env bash
# Script de construção do GCC para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/dev/gcc/gcc.sh
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
#
# OBS: este script assume que as dependências de GCC
# (GMP, MPFR, MPC, ISL, zlib) já estão presentes no sistema
# (ex: /usr/lib, /usr/include). Se você quiser empacotá-las
# via adm, crie .deps apontando para esses pacotes.

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="15.2.0"
SRC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
# Se quiser verificar integridade via MD5, preencha:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  # fail fast dentro do build
  set -euo pipefail

  echo "==> [gcc] Build iniciado"
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

  # TARGET (triplet) – tenta usar o próprio GCC
  local TARGET
  if command -v gcc >/dev/null 2>&1; then
    TARGET="$(gcc -dumpmachine)"
  else
    TARGET="${ARCH}-pc-linux-gnu"
  fi

  echo "==> [gcc] ARCH   : $ARCH"
  echo "==> [gcc] TARGET : $TARGET"
  echo "==> [gcc] CFLAGS : $SLKCFLAGS"
  echo "==> [gcc] LIBDIR : /usr/lib${LIBDIRSUFFIX}"

  #------------------------------------
  # Ajustes específicos por PROFILE
  #   EXTRA_CONFIG_FLAGS vai pro ./configure
  #------------------------------------
  local EXTRA_CONFIG_FLAGS=""
  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [gcc] Ajustes de configure para GLIBC"

      # Ativa NLS (traduções) – precisa de gettext/libintl
      EXTRA_CONFIG_FLAGS+=" --enable-nls"

      # Usar zlib do sistema (reforçando o --with-system-zlib global)
      EXTRA_CONFIG_FLAGS+=" --with-system-zlib"

      # Arquivos .a determinísticos
      EXTRA_CONFIG_FLAGS+=" --enable-deterministic-archives"

      # Se tiver problema com sanitizers / tempo de build,
      # você pode desativar algumas libs específicas:
      # EXTRA_CONFIG_FLAGS+=" --disable-libvtv"
      ;;

    musl)
      echo "==> [gcc] Ajustes de configure para MUSL"

      # Em musl é comum desabilitar NLS
      EXTRA_CONFIG_FLAGS+=" --disable-nls"

      # Usa zlib do sistema (se disponível para musl)
      EXTRA_CONFIG_FLAGS+=" --with-system-zlib"

      # Mantém arquivos determinísticos
      EXTRA_CONFIG_FLAGS+=" --enable-deterministic-archives"

      # libsanitizer costuma dar trabalho com musl,
      # é comum desabilitar em toolchains musl
      EXTRA_CONFIG_FLAGS+=" --disable-libsanitizer"

      # Se necessário, pode desabilitar outras libs extras:
      # EXTRA_CONFIG_FLAGS+=" --disable-libvtv --disable-libgomp"
      ;;

    *)
      echo "==> [gcc] PROFILE desconhecido (${PROFILE}), sem flags extras específicas"
      ;;
  esac

  #------------------------------------
  # (Opcional) ajuste t-linux64 se você quiser
  # que /usr/lib seja usado em vez de /usr/lib64.
  # Como o adm já usa LIBDIRSUFFIX=64 para x86_64,
  # vamos deixar o padrão do GCC e usar --libdir abaixo.
  #------------------------------------
  # case "$(uname -m)" in
  #   x86_64)
  #     sed -e '/m64=/s/lib64/lib/' \
  #         -i.orig gcc/config/i386/t-linux64
  #     ;;
  # esac

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
  #
  # Baseado nas opções recomendadas em LFS:
  #   --enable-languages=c,c++
  #   --enable-default-pie
  #   --enable-default-ssp
  #   --enable-host-pie
  #   --disable-multilib
  #   --disable-bootstrap
  #   --disable-fixincludes
  #   --with-system-zlib
  #------------------------------------
  CFLAGS="$SLKCFLAGS" \
  LD=ld \
  "$SRC_DIR/configure" \
    --prefix=/usr \
    --libdir=/usr/lib${LIBDIRSUFFIX} \
    --sysconfdir=/etc \
    --mandir=/usr/man \
    --infodir=/usr/info \
    --enable-languages=c,c++ \
    --enable-default-pie \
    --enable-default-ssp \
    --enable-host-pie \
    --disable-multilib \
    --disable-bootstrap \
    --disable-fixincludes \
    --with-system-zlib \
    --build="$TARGET" \
    --host="$TARGET" \
    $EXTRA_CONFIG_FLAGS

  echo "==> [gcc] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  make -j"${NUMJOBS:-1}"
  echo "==> [gcc] make concluído"

  # (Opcional) testes – desativado por padrão porque é MUITO pesado.
  # Para habilitar manualmente, descomente:
  #
  #   ulimit -s -H unlimited || true
  #   make -k check || true
  #
  # e depois confira os logs.

  #------------------------------------
  # Instalação em DESTDIR
  #------------------------------------
  make DESTDIR="$DESTDIR" install
  echo "==> [gcc] make install concluído em $DESTDIR"

  #------------------------------------
  # Pós-instalação em DESTDIR (limpezas e ajustes)
  #------------------------------------

  # 1) Remover .la (se existir)
  if command -v find >/dev/null 2>&1; then
    if [ -d "$DESTDIR/usr/lib${LIBDIRSUFFIX}" ]; then
      echo "==> [gcc] Removendo arquivos .la desnecessários"
      find "$DESTDIR/usr/lib${LIBDIRSUFFIX}" -name '*.la' -type f -print0 2>/dev/null \
        | xargs -0r rm -f
    fi
  fi

  # 2) Strip de binários e libs (sem abortar se strip não suportar algo)
  if command -v strip >/dev/null 2>&1 && command -v file >/dev/null 2>&1; then
    echo "==> [gcc] strip de binários e bibliotecas"

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
    echo "==> [gcc] strip ou file não encontrados; pulando etapa de strip"
  fi

  # 3) Compactar manpages
  if command -v gzip >/dev/null 2>&1; then
    if [ -d "$DESTDIR/usr/man" ]; then
      echo "==> [gcc] Compactando manpages"
      find "$DESTDIR/usr/man" -type f -name '*.[0-9]' -print0 2>/dev/null \
        | xargs -0r gzip -9
    fi
  fi

  # 4) Criar symlink do plugin LTO para o binutils (dentro do DESTDIR)
  #    Equivalente ao que o LFS faz em /usr/lib/bfd-plugins.
  local BFD_PLUGINS_DIR="$DESTDIR/usr/lib/bfd-plugins"
  local LTO_PLUG_REL="../../libexec/gcc/${TARGET}/${PKG_VERSION}/liblto_plugin.so"
  mkdir -p "$BFD_PLUGINS_DIR"
  if [ -f "$DESTDIR/$LTO_PLUG_REL" ]; then
    echo "==> [gcc] Criando symlink do liblto_plugin.so para binutils"
    ln -sf "$LTO_PLUG_REL" "$BFD_PLUGINS_DIR/liblto_plugin.so"
  else
    echo "==> [gcc] Aviso: liblto_plugin.so não encontrado em $DESTDIR/$LTO_PLUG_REL"
  fi

  echo "==> [gcc] Build do gcc-${PKG_VERSION} finalizado com sucesso."
}
