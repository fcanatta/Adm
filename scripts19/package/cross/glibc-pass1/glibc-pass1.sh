#!/usr/bin/env bash
# Script de construção do Glibc-2.42 - Pass 1 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/libs/glibc-pass1/glibc-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball (glibc-2.42)
#   DESTDIR  : raiz de instalação temporária (pkgroot)
#   PROFILE  : glibc / musl / outro (aqui é só log; Pass 1 é cross e não usa libc do host)
#   NUMJOBS  : número de jobs para o make
#
# Este script deve definir:
#   PKG_VERSION
#   SRC_URL
#   (opcional) SRC_MD5
#   função pkg_build()
#
# OBS:
#   - Este é o Glibc usado na fase "Cross-Toolchain" (Cap. 5.5 do LFS).
#   - Ele instala em $LFS (via DESTDIR), não no sistema host.
#   - No LFS original:
#       * aplica glibc-2.42-fhs-1.patch
#       * configure com --host=$LFS_TGT, --build=config.guess, --prefix=/usr
#       * make; make DESTDIR=$LFS install
#       * sed em $LFS/usr/bin/ldd
#   - Aqui, para o adm, usamos:
#       * make DESTDIR="$DESTDIR$LFS" install
#       * sed em "$DESTDIR$LFS/usr/bin/ldd"
#     para o pacote gerar caminhos relativos que, após instalação, viram /mnt/lfs/...

PKG_VERSION="2.42"
# Pode usar o mirror do LFS para manter coerência com o livro:
SRC_URL="https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4/glibc-${PKG_VERSION}.tar.xz"
# Alternativa oficial:
# SRC_URL="https://ftp.gnu.org/gnu/glibc/glibc-${PKG_VERSION}.tar.xz"

pkg_build() {
  set -euo pipefail

  echo "==> [glibc-pass1] Build iniciado"
  echo "    Versão   : ${PKG_VERSION}"
  echo "    SRC_DIR  : ${SRC_DIR}"
  echo "    DESTDIR  : ${DESTDIR}"
  echo "    PROFILE  : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS  : ${NUMJOBS:-1}"

  #------------------------------------
  # Verifica variáveis LFS e LFS_TGT
  #------------------------------------
  if [ -z "${LFS:-}" ]; then
    echo "ERRO: variável de ambiente LFS não está definida."
    echo "      Exemplo: export LFS=/mnt/lfs"
    exit 1
  fi

  if [ -z "${LFS_TGT:-}" ]; then
    echo "ERRO: variável de ambiente LFS_TGT não está definida."
    echo "      Exemplo: export LFS_TGT=\$(uname -m)-lfs-linux-gnu"
    exit 1
  fi

  echo "==> [glibc-pass1] LFS     = ${LFS}"
  echo "==> [glibc-pass1] LFS_TGT = ${LFS_TGT}"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [glibc-pass1] PROFILE = glibc (ou vazio) – build segue o livro LFS (cross, libc-agnóstico)."
      ;;
    musl)
      echo "==> [glibc-pass1] PROFILE = musl – informação apenas; este glibc é pro sysroot LFS."
      ;;
    *)
      echo "==> [glibc-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  #------------------------------------
  # Symlinks para LSB em $LFS (via DESTDIR)
  # (Cap. 5.5 – ln -sfv ... $LFS/lib[64]/...) 
  #------------------------------------
  echo "==> [glibc-pass1] Criando symlinks LSB dentro de $LFS (via DESTDIR)"

  mkdir -p "$DESTDIR$LFS/lib"
  case "$(uname -m)" in
    i?86)
      # ln -sfv ld-linux.so.2 $LFS/lib/ld-lsb.so.3
      ln -sfv ld-linux.so.2 "$DESTDIR$LFS/lib/ld-lsb.so.3"
      ;;
    x86_64)
      mkdir -p "$DESTDIR$LFS/lib64"
      # ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64
      ln -sfv ../lib/ld-linux-x86-64.so.2 "$DESTDIR$LFS/lib64"
      # ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64/ld-lsb-x86-64.so.3
      ln -sfv ../lib/ld-linux-x86-64.so.2 \
              "$DESTDIR$LFS/lib64/ld-lsb-x86-64.so.3"
      ;;
    *)
      echo "==> [glibc-pass1] Arquitetura não-i386/x86_64, pulando symlinks LSB específicos."
      ;;
  esac

  #------------------------------------
  # Aplicar patch FHS (glibc-2.42-fhs-1.patch)
  #------------------------------------
  local FHS_PATCH="../glibc-2.42-fhs-1.patch"

  if [ -f "$FHS_PATCH" ]; then
    echo "==> [glibc-pass1] Aplicando patch FHS: $FHS_PATCH"
    patch -Np1 -i "$FHS_PATCH"
  else
    echo "ERRO: patch FHS não encontrado em $FHS_PATCH"
    echo "      Baixe glibc-2.42-fhs-1.patch e coloque ao lado do tarball do glibc."
    exit 1
  fi

  #------------------------------------
  # Diretório de build separado
  #------------------------------------
  echo "==> [glibc-pass1] Criando diretório de build"
  rm -rf build
  mkdir -p build
  cd build

  # Garantir ldconfig/sln em /usr/sbin (dentro de $LFS depois)
  echo "rootsbindir=/usr/sbin" > configparms

  #------------------------------------
  # Configure (igual ao LFS 5.5, com DESTDIR depois no make install)
  #
  # ../configure                             \
  #       --prefix=/usr                      \
  #       --host=$LFS_TGT                    \
  #       --build=$(../scripts/config.guess) \
  #       --disable-nscd                     \
  #       libc_cv_slibdir=/usr/lib           \
  #       --enable-kernel=5.4
  #------------------------------------
  echo "==> [glibc-pass1] Rodando configure (cross, host=$LFS_TGT)"
  ../configure                             \
        --prefix=/usr                      \
        --host="$LFS_TGT"                  \
        --build="$(../scripts/config.guess)" \
        --disable-nscd                     \
        libc_cv_slibdir=/usr/lib           \
        --enable-kernel=5.4

  echo "==> [glibc-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [glibc-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [glibc-pass1] make concluído"

  #------------------------------------
  # Instalação em $LFS via DESTDIR do adm
  #
  # LFS faz:
  #   make DESTDIR=$LFS install
  #
  # Aqui fazemos:
  #   make DESTDIR="$DESTDIR$LFS" install
  #
  # O pacote resultante terá caminhos relativos "mnt/lfs/usr/...",
  # e quando o adm instalar esse tarball em /, os arquivos vão
  # parar em /mnt/lfs/usr/... como o livro espera.
  #------------------------------------
  echo "==> [glibc-pass1] Instalando em DESTDIR=${DESTDIR}${LFS}"
  mkdir -p "$DESTDIR$LFS"
  make DESTDIR="$DESTDIR$LFS" install

  #------------------------------------
  # Ajustar ldd dentro de $LFS (via DESTDIR)
  #
  # LFS:
  #   sed '/RTLDLIST=/s@/usr@@g' -i $LFS/usr/bin/ldd
  #------------------------------------
  local LDD_PATH="$DESTDIR$LFS/usr/bin/ldd"
  if [ -f "$LDD_PATH" ]; then
    echo "==> [glibc-pass1] Ajustando RTLDLIST em $LDD_PATH"
    sed -i '/RTLDLIST=/s@/usr@@g' "$LDD_PATH"
  else
    echo "AVISO: $LDD_PATH não encontrado; ajuste de ldd não aplicado."
  fi

  echo "==> [glibc-pass1] Glibc-2.42 Pass 1 instalado em $DESTDIR$LFS"
  echo "==> [glibc-pass1] Build concluído com sucesso."
}
