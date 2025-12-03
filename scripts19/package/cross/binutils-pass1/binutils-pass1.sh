#!/usr/bin/env bash
# Script de construção do Binutils-2.45.1 - Pass 1 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/binutils-pass1/binutils-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball
#   DESTDIR  : raiz de instalação temporária (pkgroot)
#   PROFILE  : glibc / musl / outro (não usado aqui)
#   NUMJOBS  : número de jobs para o make
#
# Este script deve definir:
#   PKG_VERSION
#   SRC_URL
#   (opcional) SRC_MD5
#   função pkg_build()
#
# OBS:
#   - Este é o Binutils PASS 1 (cross-binutils), no estilo LFS.
#   - Ele assume que as variáveis de ambiente LFS e LFS_TGT estão
#     corretamente configuradas, como no livro LFS:
#       export LFS=/mnt/lfs
#       export LFS_TGT=$(uname -m)-lfs-linux-gnu   (exemplo)
#   - PREFIX é /tools (como no LFS); com DESTDIR o adm empacota
#     arquivos em /tools/... dentro do tarball.

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="2.45.1"
SRC_URL="https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
# Opcional:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [binutils-pass1] Build iniciado"
  echo "    Versão   : ${PKG_VERSION}"
  echo "    SRC_DIR  : ${SRC_DIR}"
  echo "    DESTDIR  : ${DESTDIR}"
  echo "    PROFILE  : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS  : ${NUMJOBS:-1}"

  #------------------------------------
  # Checar ambiente LFS / LFS_TGT (como no livro LFS)
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

  echo "==> [binutils-pass1] LFS     = $LFS"
  echo "==> [binutils-pass1] LFS_TGT = $LFS_TGT"

  cd "$SRC_DIR"

  #------------------------------------
  # Diretório de build dedicado (recomendação do Binutils/LFS) 
  #------------------------------------
  rm -rf build
  mkdir -p build
  cd build

  #------------------------------------
  # Configure (igual ao LFS - Pass 1) 
  #
  # ../configure --prefix=$LFS/tools \
  #              --with-sysroot=$LFS \
  #              --target=$LFS_TGT   \
  #              --disable-nls       \
  #              --enable-gprofng=no \
  #              --disable-werror    \
  #              --enable-new-dtags  \
  #              --enable-default-hash-style=gnu
  #
  # Adaptado para o adm:
  #   - prefix=/tools (sem $LFS), para que no tarball os paths sejam /tools/...
  #   - with-sysroot=$LFS, igual ao LFS (precisa do root real, não do DESTDIR)
  #
  # Quando o adm instalar o pacote (untar em /), o resultado final
  # será /tools/bin, /tools/lib, etc., igual ao LFS.
  #------------------------------------
  ../configure \
    --prefix=/tools \
    --with-sysroot="$LFS" \
    --target="$LFS_TGT" \
    --disable-nls \
    --enable-gprofng=no \
    --disable-werror \
    --enable-new-dtags \
    --enable-default-hash-style=gnu

  echo "==> [binutils-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  make -j"${NUMJOBS:-1}"
  echo "==> [binutils-pass1] make concluído"

  #------------------------------------
  # Instalação em DESTDIR
  #
  # LFS manda: make install (direto em $LFS/tools).
  # Aqui usamos DESTDIR para empacotar: os arquivos vão para
  #   $DESTDIR/tools/...
  # No momento da instalação, o adm vai extrair o pacote em /,
  # resultando em /tools/... igual ao LFS.
  #------------------------------------
  make DESTDIR="$DESTDIR" install
  echo "==> [binutils-pass1] make install concluído em $DESTDIR"

  echo "==> [binutils-pass1] Build do Binutils-${PKG_VERSION} - Pass 1 finalizado com sucesso."
}
