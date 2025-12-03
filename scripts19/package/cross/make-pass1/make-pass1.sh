#!/usr/bin/env bash
# Script de construção do Make-4.4.1 - Pass 1 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/make-pass1/make-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball (make-4.4.1)
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
#   - Instalar make dentro do sysroot do LFS ($LFS/usr)
#   - Suportar cross-compile se LFS_TGT estiver definido
#   - Seguir o padrão dos outros pacotes pass1 do adm

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="4.4.1"
SRC_URL="https://ftp.gnu.org/gnu/make/make-${PKG_VERSION}.tar.gz"
# Se quiser, você pode preencher depois o MD5 correspondente:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [make-pass1] Build iniciado"
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

  echo "==> [make-pass1] LFS = ${LFS}"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [make-pass1] PROFILE = glibc (ou vazio) – apenas informativo."
      ;;
    musl)
      echo "==> [make-pass1] PROFILE = musl – make não muda aqui, só log."
      ;;
    *)
      echo "==> [make-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e CFLAGS
  #------------------------------------
  local ARCH CFLAGS_MAKE
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i386
      CFLAGS_MAKE="-O2 -pipe"
      ;;
    x86_64)
      CFLAGS_MAKE="-O2 -pipe"
      ;;
    *)
      CFLAGS_MAKE="-O2 -pipe"
      ;;
  esac

  echo "==> [make-pass1] ARCH   : $ARCH"
  echo "==> [make-pass1] CFLAGS : $CFLAGS_MAKE"

  #------------------------------------
  # Opções de host/build (cross ou nativo)
  #------------------------------------
  local HOST_OPTS=""
  if [ -n "${LFS_TGT:-}" ]; then
    echo "==> [make-pass1] LFS_TGT = ${LFS_TGT} (cross)"
    if [ -x "./build-aux/config.guess" ]; then
      local BUILD_TRIPLET
      BUILD_TRIPLET="$(./build-aux/config.guess)"
      HOST_OPTS="--host=${LFS_TGT} --build=${BUILD_TRIPLET}"
      echo "==> [make-pass1] BUILD triplet detectado: ${BUILD_TRIPLET}"
    else
      echo "AVISO: build-aux/config.guess não encontrado; usando apenas --host=${LFS_TGT}"
      HOST_OPTS="--host=${LFS_TGT}"
    fi
  else
    echo "==> [make-pass1] LFS_TGT não definido; build nativo para o ambiente atual."
  fi

  #------------------------------------
  # Configure
  #
  # Para Pass1, queremos make em $LFS/usr,
  # então usamos --prefix=/usr e instalamos com DESTDIR="$DESTDIR$LFS"
  #------------------------------------
  echo "==> [make-pass1] Rodando ./configure..."
  CFLAGS="$CFLAGS_MAKE" \
  ./configure \
    --prefix=/usr \
    $HOST_OPTS

  echo "==> [make-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [make-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [make-pass1] make concluído"

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
  # echo "==> [make-pass1] Rodando test suite (opcional)..."
  # make check || true

  #------------------------------------
  # Instalação em $LFS via DESTDIR do adm
  #------------------------------------
  echo "==> [make-pass1] Instalando em DESTDIR=${DESTDIR}${LFS}"
  mkdir -p "$DESTDIR$LFS"
  make DESTDIR="$DESTDIR$LFS" install

  echo "==> [make-pass1] Make-${PKG_VERSION} instalado em $DESTDIR$LFS/usr"

  #------------------------------------
  # Pós-instalação mínima
  #
  # Normalmente não há hacks especiais aqui no Pass1.
  # Se quiser limpar docs, exemplos ou ajustar algo,
  # pode fazer neste bloco.
  #------------------------------------
  echo "==> [make-pass1] Build do Make-${PKG_VERSION} Pass 1 finalizado com sucesso."
}
