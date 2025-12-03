#!/usr/bin/env bash
# Script de construção do File-5.46 - Pass 1 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/file-pass1/file-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball (file-5.46)
#   DESTDIR  : raiz de instalação temporária (pkgroot)
#   PROFILE  : glibc / musl / outro (aqui é só log)
#   NUMJOBS  : número de jobs para o make
#
# Este script deve definir:
#   PKG_VERSION
#   SRC_URL
#   (opcional) SRC_MD5
#   função pkg_build()
#
# Baseado nas instruções do LFS para File-5.46 (Capítulo 6, Ferramentas Temporárias),
# adaptadas para o fluxo do adm:
#   - build nativo em ./build para gerar um "file" temporário
#   - configure cross (--host=$LFS_TGT --build=$(./config.guess))
#   - make FILE_COMPILE=$(pwd)/build/src/file
#   - make DESTDIR=$LFS install
#   - rm -v $LFS/usr/lib/libmagic.la

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="5.46"
# Tarball oficial do projeto file
SRC_URL="ftp://ftp.astron.com/pub/file/file-${PKG_VERSION}.tar.gz"
# Se quiser, pegue o MD5 do tarball do mirror de pacotes do LFS e preencha aqui:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [file-pass1] Build iniciado"
  echo "    Versão   : ${PKG_VERSION}"
  echo "    SRC_DIR  : ${SRC_DIR}"
  echo "    DESTDIR  : ${DESTDIR}"
  echo "    PROFILE  : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS  : ${NUMJOBS:-1}"

  #------------------------------------
  # LFS é obrigatório (sysroot alvo)
  #------------------------------------
  if [ -z "${LFS:-}" ]; then
    echo "ERRO: variável de ambiente LFS não está definida."
    echo "      Exemplo: export LFS=/mnt/lfs"
    exit 1
  fi

  echo "==> [file-pass1] LFS = ${LFS}"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [file-pass1] PROFILE = glibc (ou vazio) – apenas informativo para o sysroot $LFS."
      ;;
    musl)
      echo "==> [file-pass1] PROFILE = musl – apenas log; a receita do File é a mesma."
      ;;
    *)
      echo "==> [file-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e CFLAGS
  #------------------------------------
  local ARCH CFLAGS_FILE
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i386
      CFLAGS_FILE="-O2 -pipe"
      ;;
    x86_64)
      CFLAGS_FILE="-O2 -pipe"
      ;;
    *)
      CFLAGS_FILE="-O2 -pipe"
      ;;
  esac

  echo "==> [file-pass1] ARCH   : $ARCH"
  echo "==> [file-pass1] CFLAGS : $CFLAGS_FILE"

  #------------------------------------
  # 1ª etapa: build nativo em ./build
  #
  # Essa etapa gera um binário "file" de host, usado depois em
  # FILE_COMPILE=$(pwd)/build/src/file ao compilar para o alvo.
  #------------------------------------
  echo "==> [file-pass1] Construindo cópia temporária de host (./build)..."
  mkdir -p build
  pushd build > /dev/null

  CFLAGS="$CFLAGS_FILE" \
  ../configure \
    --disable-bzlib      \
    --disable-libseccomp \
    --disable-xzlib      \
    --disable-zlib

  echo "==> [file-pass1] configure (host) concluído"
  make -j"${NUMJOBS:-1}"
  echo "==> [file-pass1] make (host) concluído"

  popd > /dev/null

  #------------------------------------
  # 2ª etapa: configure para o alvo (cross)
  #
  # ./configure --prefix=/usr --host=$LFS_TGT --build=$(./config.guess)
  #------------------------------------
  local HOST_OPTS=""
  if [ -n "${LFS_TGT:-}" ]; then
    echo "==> [file-pass1] LFS_TGT = ${LFS_TGT} (cross)"
    if [ -x "./config.guess" ]; then
      local BUILD_TRIPLET
      BUILD_TRIPLET="$(./config.guess)"
      HOST_OPTS="--host=${LFS_TGT} --build=${BUILD_TRIPLET}"
      echo "==> [file-pass1] BUILD triplet detectado: ${BUILD_TRIPLET}"
    else
      echo "AVISO: ./config.guess não encontrado; usando apenas --host=${LFS_TGT}"
      HOST_OPTS="--host=${LFS_TGT}"
    fi
  else
    echo "==> [file-pass1] LFS_TGT não definido; configurando File-5.46 como nativo."
  fi

  echo "==> [file-pass1] Rodando ./configure (alvo)..."
  CFLAGS="$CFLAGS_FILE" \
  ./configure \
    --prefix=/usr \
    $HOST_OPTS

  echo "==> [file-pass1] configure (alvo) concluído"

  #------------------------------------
  # 3ª etapa: compilação "cross"
  #
  # make FILE_COMPILE=$(pwd)/build/src/file
  #------------------------------------
  echo "==> [file-pass1] Compilando para o alvo..."
  make -j"${NUMJOBS:-1}" FILE_COMPILE="$(pwd)/build/src/file"
  echo "==> [file-pass1] make (alvo) concluído"

  #------------------------------------
  # 4ª etapa: instalação em $LFS via DESTDIR do adm
  #
  # make DESTDIR=$LFS install
  # + remoção de libmagic.la
  #------------------------------------
  echo "==> [file-pass1] Instalando em DESTDIR=${DESTDIR}${LFS}"
  mkdir -p "$DESTDIR$LFS"
  make DESTDIR="$DESTDIR$LFS" install

  # Remover libtool archive que atrapalha cross-builds posteriores
  if [ -f "$DESTDIR$LFS/usr/lib/libmagic.la" ]; then
    echo "==> [file-pass1] Removendo libmagic.la (recomendação LFS)..."
    rm -v "$DESTDIR$LFS/usr/lib/libmagic.la"
  else
    echo "==> [file-pass1] libmagic.la não encontrada em $DESTDIR$LFS/usr/lib (ok)."
  fi

  echo "==> [file-pass1] File-${PKG_VERSION} instalado em $DESTDIR$LFS/usr"

  #------------------------------------
  # Pós-instalação mínima
  #
  # Nada especial aqui além da remoção do .la. Se quiser limpar docs ou
  # info, faça aqui respeitando o seu layout.
  #------------------------------------
  echo "==> [file-pass1] Build do File-${PKG_VERSION} Pass 1 finalizado com sucesso."
}
