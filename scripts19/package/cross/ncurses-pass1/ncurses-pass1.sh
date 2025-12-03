#!/usr/bin/env bash
# Script de construção do Ncurses-6.5-20250809 - Pass 1 (temporary tools) para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/ncurses-pass1/ncurses-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído (ncurses-6.5-20250809)
#   DESTDIR  : raiz de instalação temporária (pkgroot do pacote)
#   PROFILE  : glibc / musl / outro (apenas log aqui)
#   NUMJOBS  : número de jobs para o make
#
# Ambiente necessário (estilo LFS, Cap. 6.3):
#   export LFS=/mnt/lfs
#   export LFS_TGT=$(uname -m)-lfs-linux-gnu
#
# Esse script faz duas coisas, como no LFS:
#   1) constrói e instala um tic nativo em $LFS/tools/bin (sem DESTDIR)
#   2) constrói o ncurses "cross" e instala em $LFS via DESTDIR="$DESTDIR$LFS"

PKG_VERSION="6.5-20250809"
SRC_URL="https://www.linuxfromscratch.org/lfs/downloads/development/ncurses-${PKG_VERSION}.tar.xz"

pkg_build() {
  set -euo pipefail

  echo "==> [ncurses-pass1] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS : ${NUMJOBS:-1}"

  #------------------------------------
  # LFS / LFS_TGT (obrigatórios)
  #------------------------------------
  if [ -z "${LFS:-}" ]; then
    echo "ERRO: variável LFS não está definida (ex: /mnt/lfs)."
    exit 1
  fi
  if [ -z "${LFS_TGT:-}" ]; then
    echo "ERRO: variável LFS_TGT não está definida (ex: \$(uname -m)-lfs-linux-gnu)."
    exit 1
  fi

  echo "==> [ncurses-pass1] LFS     = $LFS"
  echo "==> [ncurses-pass1] LFS_TGT = $LFS_TGT"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [ncurses-pass1] PROFILE = glibc (ou vazio) – toolkit temporário para sysroot glibc."
      ;;
    musl)
      echo "==> [ncurses-pass1] PROFILE = musl – ainda assim seguimos receita do LFS (glbic-style), ajusta depois se precisar."
      ;;
    *)
      echo "==> [ncurses-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  #------------------------------------
  # 1) Construir e instalar tic nativo em $LFS/tools/bin
  #    (como em 6.3.1: mkdir build; configure; make -C include/progs; install tic)
  #    Isso NÃO vai para o pacote do adm; é side-effect necessário pro build.
  #------------------------------------
  echo "==> [ncurses-pass1] Construindo tic nativo para $LFS/tools"

  rm -rf build-tic
  mkdir -p build-tic
  pushd build-tic > /dev/null

  ../configure --prefix="$LFS/tools" AWK=gawk

  # Só os pedaços necessários pra tic
  make -C include
  make -C progs tic

  mkdir -p "$LFS/tools/bin"
  install -m 0755 progs/tic "$LFS/tools/bin/tic"

  popd > /dev/null
  echo "==> [ncurses-pass1] tic instalado em $LFS/tools/bin/tic"

  #------------------------------------
  # 2) Preparar build cross do Ncurses em si
  #    (como na página: ./configure --prefix=/usr ... --host=$LFS_TGT ...)
  #------------------------------------
  echo "==> [ncurses-pass1] Configurando ncurses para cross-compilar para $LFS_TGT"

  ./configure --prefix=/usr                \
              --host="$LFS_TGT"            \
              --build="$(./config.guess)"  \
              --mandir=/usr/share/man      \
              --with-manpage-format=normal \
              --with-shared                \
              --without-normal             \
              --with-cxx-shared            \
              --without-debug              \
              --without-ada                \
              --disable-stripping          \
              AWK=gawk

  echo "==> [ncurses-pass1] configure concluído"

  #------------------------------------
  # Compilar (make)
  #------------------------------------
  echo "==> [ncurses-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [ncurses-pass1] make concluído"

  #------------------------------------
  # Instalar em $LFS via DESTDIR do adm
  #   LFS manda:
  #     make DESTDIR=$LFS install
  #
  #   Aqui:
  #     make DESTDIR="$DESTDIR$LFS" install
  #
  #   O pacote do adm vai conter "mnt/lfs/usr/..." e,
  #   depois da instalação, você terá /mnt/lfs/usr/... igual ao livro.
  #------------------------------------
  echo "==> [ncurses-pass1] Instalando em DESTDIR=${DESTDIR}${LFS}"
  mkdir -p "$DESTDIR$LFS"
  make DESTDIR="$DESTDIR$LFS" install

  #------------------------------------
  # Symlink libncurses.so -> libncursesw.so em $LFS/usr/lib
  #   ln -sv libncursesw.so $LFS/usr/lib/libncurses.so
  #------------------------------------
  local LIBDIR="$DESTDIR$LFS/usr/lib"
  mkdir -p "$LIBDIR"

  echo "==> [ncurses-pass1] Criando symlink libncurses.so -> libncursesw.so em $LIBDIR"
  ln -sfv libncursesw.so "$LIBDIR/libncurses.so"

  #------------------------------------
  # Ajustar curses.h para forçar wide-char
  #   sed -e 's/^#if.*XOPEN.*$/#if 1/' -i $LFS/usr/include/curses.h
  #------------------------------------
  local CURSES_H="$DESTDIR$LFS/usr/include/curses.h"
  if [ -f "$CURSES_H" ]; then
    echo "==> [ncurses-pass1] Ajustando $CURSES_H para usar sempre estruturas wide-character"
    sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "$CURSES_H"
  else
    echo "AVISO: $CURSES_H não encontrado; verifique se a instalação do ncurses-pass1 foi correta."
  fi

  echo "==> [ncurses-pass1] Ncurses-${PKG_VERSION} Pass 1 instalado em $DESTDIR$LFS"
  echo "==> [ncurses-pass1] Build concluído com sucesso."
}
