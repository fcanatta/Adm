#!/usr/bin/env bash
# Script de construção do Libstdc++ from GCC-15.2.0 - Pass 1 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/libstdcxx-pass1/libstdcxx-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído de gcc-15.2.0
#   DESTDIR  : raiz de instalação temporária (pkgroot)
#   PROFILE  : glibc / musl / outro (aqui é só log; libstdc++ Pass 1 segue o LFS)
#   NUMJOBS  : número de jobs para o make
#
# Este script deve definir:
#   PKG_VERSION
#   SRC_URL
#   função pkg_build()
#
# OBS:
#   - Este pacote é a libstdc++ “alvo” (target) do capítulo 5.6 do LFS 12.4.
#   - Ele supõe que:
#       * gcc-pass1 já foi construído/instalado
#       * glibc-pass1 já está no $LFS
#       * linux-headers já foram instalados em $LFS/usr/include
#   - A árvore de origem é a do GCC, ou seja, SRC_DIR == gcc-15.2.0.

PKG_VERSION="15.2.0"
SRC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
# (pode usar o mirror do LFS se preferir)

pkg_build() {
  set -euo pipefail

  echo "==> [libstdcxx-pass1] Build iniciado"
  echo "    Versão   : ${PKG_VERSION}"
  echo "    SRC_DIR  : ${SRC_DIR}"
  echo "    DESTDIR  : ${DESTDIR}"
  echo "    PROFILE  : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS  : ${NUMJOBS:-1}"

  #------------------------------------
  # Verifica ambiente LFS / LFS_TGT
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

  echo "==> [libstdcxx-pass1] LFS     = $LFS"
  echo "==> [libstdcxx-pass1] LFS_TGT = $LFS_TGT"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [libstdcxx-pass1] PROFILE = glibc (ou vazio) – libstdc++ Pass 1 segue o LFS, libc alvo é a glibc em $LFS."
      ;;
    musl)
      echo "==> [libstdcxx-pass1] PROFILE = musl – informação só; este build ainda é para o sysroot LFS com glibc."
      ;;
    *)
      echo "==> [libstdcxx-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  # Tentativa de sanity básica: verificar se isto parece um source de gcc
  if [ ! -d "libstdc++-v3" ] || [ ! -f "config.guess" ]; then
    echo "ERRO: SRC_DIR não parece ser o source do GCC (faltam libstdc++-v3/ ou config.guess)."
    echo "      Certifique-se de que o adm extraiu gcc-${PKG_VERSION}.tar.xz aqui."
    exit 1
  fi

  #------------------------------------
  # Diretório de build dedicado para libstdc++
  # (separado do build do gcc-pass1)
  #------------------------------------
  echo "==> [libstdcxx-pass1] Criando diretório de build"
  rm -rf build-libstdcxx
  mkdir -p build-libstdcxx
  cd build-libstdcxx

  #------------------------------------
  # Configure (igual ao LFS 5.6, adaptado para DESTDIR depois)
  #
  # ../libstdc++-v3/configure      \
  #   --host=$LFS_TGT            \
  #   --build=$(../config.guess) \
  #   --prefix=/usr              \
  #   --disable-multilib         \
  #   --disable-nls              \
  #   --disable-libstdcxx-pch    \
  #   --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/15.2.0
  #------------------------------------
  echo "==> [libstdcxx-pass1] Rodando configure de libstdc++"
  ../libstdc++-v3/configure      \
    --host="$LFS_TGT"            \
    --build="$(../config.guess)" \
    --prefix=/usr                \
    --disable-multilib           \
    --disable-nls                \
    --disable-libstdcxx-pch      \
    --with-gxx-include-dir="/tools/$LFS_TGT/include/c++/${PKG_VERSION}"

  echo "==> [libstdcxx-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [libstdcxx-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [libstdcxx-pass1] make concluído"

  #------------------------------------
  # Instalação em $LFS via DESTDIR do adm
  #
  # LFS:
  #   make DESTDIR=$LFS install
  #
  # Aqui:
  #   make DESTDIR="$DESTDIR$LFS" install
  #
  # Assim o pacote gerado pelo adm tem caminhos relativos mnt/lfs/usr/...
  # e, ao instalar, cai em /mnt/lfs/usr/... igual o livro.
  #------------------------------------
  echo "==> [libstdcxx-pass1] Instalando em DESTDIR=${DESTDIR}${LFS}"
  mkdir -p "$DESTDIR$LFS"
  make DESTDIR="$DESTDIR$LFS" install

  #------------------------------------
  # Remover arquivos .la de libstdc++ no sysroot ($LFS),
  # como manda o LFS:
  #   rm -v $LFS/usr/lib/lib{stdc++{,exp,fs},supc++}.la
  #------------------------------------
  echo "==> [libstdcxx-pass1] Removendo .la 'nocivos' em $LFS/usr/lib"
  local LIBDIR="$DESTDIR$LFS/usr/lib"

  if [ -d "$LIBDIR" ]; then
    rm -fv "$LIBDIR"/libstdc++.la \
           "$LIBDIR"/libstdc++exp.la \
           "$LIBDIR"/libstdc++fs.la \
           "$LIBDIR"/libsupc++.la || true
  else
    echo "AVISO: diretório $LIBDIR não existe; nada para remover."
  fi

  echo "==> [libstdcxx-pass1] Libstdc++ from GCC-${PKG_VERSION} (Pass 1) instalado em $DESTDIR$LFS"
  echo "==> [libstdcxx-pass1] Build concluído com sucesso."
}
