#!/usr/bin/env bash
# Script de construção do Gzip-1.14 - Pass 1 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/gzip-pass1/gzip-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball (gzip-1.14)
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
#   - Instalar gzip dentro do sysroot do LFS ($LFS/usr)
#   - Suportar cross-compile se LFS_TGT estiver definido
#   - Seguir o padrão dos outros pacotes pass1 do adm

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="1.14"
SRC_URL="https://ftp.gnu.org/gnu/gzip/gzip-${PKG_VERSION}.tar.xz"
# Se quiser, você pode preencher depois o MD5 correspondente:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [gzip-pass1] Build iniciado"
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

  echo "==> [gzip-pass1] LFS = ${LFS}"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [gzip-pass1] PROFILE = glibc (ou vazio) – apenas informativo."
      ;;
    musl)
      echo "==> [gzip-pass1] PROFILE = musl – gzip é agnóstico de libc aqui, só log."
      ;;
    *)
      echo "==> [gzip-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e CFLAGS
  #------------------------------------
  local ARCH CFLAGS_GZIP
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i386
      CFLAGS_GZIP="-O2 -pipe"
      ;;
    x86_64)
      CFLAGS_GZIP="-O2 -pipe"
      ;;
    *)
      CFLAGS_GZIP="-O2 -pipe"
      ;;
  esac

  echo "==> [gzip-pass1] ARCH   : $ARCH"
  echo "==> [gzip-pass1] CFLAGS : $CFLAGS_GZIP"

  #------------------------------------
  # Opções de host/build (cross ou nativo)
  #------------------------------------
  local HOST_OPTS=""
  if [ -n "${LFS_TGT:-}" ]; then
    echo "==> [gzip-pass1] LFS_TGT = ${LFS_TGT} (cross)"
    if [ -x "./config.guess" ]; then
      local BUILD_TRIPLET
      BUILD_TRIPLET="$(./config.guess)"
      HOST_OPTS="--host=${LFS_TGT} --build=${BUILD_TRIPLET}"
      echo "==> [gzip-pass1] BUILD triplet detectado: ${BUILD_TRIPLET}"
    else
      echo "AVISO: ./config.guess não encontrado; usando apenas --host=${LFS_TGT}"
      HOST_OPTS="--host=${LFS_TGT}"
    fi
  else
    echo "==> [gzip-pass1] LFS_TGT não definido; build nativo para o ambiente atual."
  fi

  #------------------------------------
  # Configure
  #
  # Para Pass1, queremos gzip em $LFS/usr,
  # então usamos --prefix=/usr e instalamos com DESTDIR="$DESTDIR$LFS"
  #------------------------------------
  echo "==> [gzip-pass1] Rodando ./configure..."
  CFLAGS="$CFLAGS_GZIP" \
  ./configure \
    --prefix=/usr \
    $HOST_OPTS

  echo "==> [gzip-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [gzip-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [gzip-pass1] make concluído"

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
  # echo "==> [gzip-pass1] Rodando test suite (opcional)..."
  # make check || true

  #------------------------------------
  # Instalação em $LFS via DESTDIR do adm
  #------------------------------------
  echo "==> [gzip-pass1] Instalando em DESTDIR=${DESTDIR}${LFS}"
  mkdir -p "$DESTDIR$LFS"
  make DESTDIR="$DESTDIR$LFS" install

  echo "==> [gzip-pass1] Gzip-${PKG_VERSION} instalado em $DESTDIR$LFS/usr"

  #------------------------------------
  # Pós-instalação mínima
  #
  # Se quiser seguir idêntico ao LFS em algum ajuste extra (ex.: links
  # simbólicos, limpeza de docs), você pode colocar aqui.
  # Por padrão, não é necessário nada especial no Pass1.
  #------------------------------------
  echo "==> [gzip-pass1] Build do Gzip-${PKG_VERSION} Pass 1 finalizado com sucesso."
}
