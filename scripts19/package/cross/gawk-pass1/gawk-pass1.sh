#!/usr/bin/env bash
# Script de construção do Gawk-5.3.2 - Pass 1 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/gawk-pass1/gawk-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball (gawk-5.3.2)
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
# Objetivo do Pass 1:
#   - Instalar gawk dentro do sysroot do LFS ($LFS/usr)
#   - Suportar cross-compile se LFS_TGT estiver definido
#   - Seguir o modelo dos outros pacotes pass1 do adm

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="5.3.2"
SRC_URL="https://ftp.gnu.org/gnu/gawk/gawk-${PKG_VERSION}.tar.xz"
# Se quiser, você pode preencher depois o MD5 correspondente:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [gawk-pass1] Build iniciado"
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

  echo "==> [gawk-pass1] LFS = ${LFS}"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [gawk-pass1] PROFILE = glibc (ou vazio) – apenas informativo."
      ;;
    musl)
      echo "==> [gawk-pass1] PROFILE = musl – gawk é agnóstico de libc aqui, só log."
      ;;
    *)
      echo "==> [gawk-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e CFLAGS
  #------------------------------------
  local ARCH CFLAGS_GAWK
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i386
      CFLAGS_GAWK="-O2 -pipe"
      ;;
    x86_64)
      CFLAGS_GAWK="-O2 -pipe"
      ;;
    *)
      CFLAGS_GAWK="-O2 -pipe"
      ;;
  esac

  echo "==> [gawk-pass1] ARCH   : $ARCH"
  echo "==> [gawk-pass1] CFLAGS : $CFLAGS_GAWK"

  #------------------------------------
  # Opções de host/build (cross ou nativo)
  #------------------------------------
  local HOST_OPTS=""
  if [ -n "${LFS_TGT:-}" ]; then
    echo "==> [gawk-pass1] LFS_TGT = ${LFS_TGT} (cross)"
    if [ -x "./config.guess" ]; then
      local BUILD_TRIPLET
      BUILD_TRIPLET="$(./config.guess)"
      HOST_OPTS="--host=${LFS_TGT} --build=${BUILD_TRIPLET}"
      echo "==> [gawk-pass1] BUILD triplet detectado: ${BUILD_TRIPLET}"
    else
      echo "AVISO: ./config.guess não encontrado; usando apenas --host=${LFS_TGT}"
      HOST_OPTS="--host=${LFS_TGT}"
    fi
  else
    echo "==> [gawk-pass1] LFS_TGT não definido; build nativo para o ambiente atual."
  fi

  #------------------------------------
  # Configure
  #
  # Para Pass1, queremos gawk em $LFS/usr,
  # então usamos --prefix=/usr e instalamos com DESTDIR="$DESTDIR$LFS"
  #------------------------------------
  echo "==> [gawk-pass1] Rodando ./configure..."
  CFLAGS="$CFLAGS_GAWK" \
  ./configure \
    --prefix=/usr \
    $HOST_OPTS

  echo "==> [gawk-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [gawk-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [gawk-pass1] make concluído"

  #------------------------------------
  # Testes (opcionais)
  #
  # Em ambiente cross (fora de chroot), normalmente os testes
  # são pulados, pois dependem do runtime do alvo.
  #
  # Se você estiver num chroot já dentro de $LFS, pode habilitar:
  #
  #   make check
  #
  #------------------------------------
  # echo "==> [gawk-pass1] Rodando test suite (opcional)..."
  # make check || true

  #------------------------------------
  # Instalação em $LFS via DESTDIR do adm
  #------------------------------------
  echo "==> [gawk-pass1] Instalando em DESTDIR=${DESTDIR}${LFS}"
  mkdir -p "$DESTDIR$LFS"
  make DESTDIR="$DESTDIR$LFS" install

  echo "==> [gawk-pass1] Gawk-${PKG_VERSION} instalado em $DESTDIR$LFS/usr"

  #------------------------------------
  # Pós-instalação mínima
  #
  # Aqui normalmente não é necessário nenhum hack específico
  # para o Pass1. Se você quiser remover docs extras ou exemplos,
  # pode fazê-lo aqui, levando em conta o seu layout.
  #------------------------------------
  echo "==> [gawk-pass1] Build do Gawk-${PKG_VERSION} Pass 1 finalizado com sucesso."
}
