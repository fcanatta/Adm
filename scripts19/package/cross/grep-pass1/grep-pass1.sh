#!/usr/bin/env bash
# Script de construção do Grep-3.12 - Pass 1 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/grep-pass1/grep-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball (grep-3.12)
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
#   - Instalar grep dentro do sysroot do LFS ($LFS/usr)
#   - Suportar cross-compile se LFS_TGT estiver definido
#   - Seguir o padrão dos outros pacotes pass1 do adm

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="3.12"
SRC_URL="https://ftp.gnu.org/gnu/grep/grep-${PKG_VERSION}.tar.xz"
# Se quiser, você pode preencher depois o MD5 correspondente:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [grep-pass1] Build iniciado"
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

  echo "==> [grep-pass1] LFS = ${LFS}"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [grep-pass1] PROFILE = glibc (ou vazio) – apenas informativo."
      ;;
    musl)
      echo "==> [grep-pass1] PROFILE = musl – grep é agnóstico aqui, só log."
      ;;
    *)
      echo "==> [grep-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e CFLAGS
  #------------------------------------
  local ARCH CFLAGS_GREP
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i386
      CFLAGS_GREP="-O2 -pipe"
      ;;
    x86_64)
      CFLAGS_GREP="-O2 -pipe"
      ;;
    *)
      CFLAGS_GREP="-O2 -pipe"
      ;;
  esac

  echo "==> [grep-pass1] ARCH   : $ARCH"
  echo "==> [grep-pass1] CFLAGS : $CFLAGS_GREP"

  #------------------------------------
  # Opções de host/build (cross ou nativo)
  #------------------------------------
  local HOST_OPTS=""
  if [ -n "${LFS_TGT:-}" ]; then
    echo "==> [grep-pass1] LFS_TGT = ${LFS_TGT} (cross)"
    if [ -x "./build-aux/config.guess" ]; then
      local BUILD_TRIPLET
      BUILD_TRIPLET="$(./build-aux/config.guess)"
      HOST_OPTS="--host=${LFS_TGT} --build=${BUILD_TRIPLET}"
      echo "==> [grep-pass1] BUILD triplet detectado: ${BUILD_TRIPLET}"
    else
      echo "AVISO: build-aux/config.guess não encontrado; usando apenas --host=${LFS_TGT}"
      HOST_OPTS="--host=${LFS_TGT}"
    fi
  else
    echo "==> [grep-pass1] LFS_TGT não definido; build nativo para o ambiente atual."
  fi

  #------------------------------------
  # Ajustes opcionais de compatibilidade
  #
  # Em algumas versões antigas do LFS se ajustava scripts egrep/fgrep.
  # Nas versões recentes de grep isso não é mais necessário para o Pass1.
  # Se você quiser algo específico, pode adicionar aqui.
  #------------------------------------

  #------------------------------------
  # Configure
  #
  # Para Pass1, queremos grep em $LFS/usr,
  # então usamos --prefix=/usr e instalamos com DESTDIR="$DESTDIR$LFS"
  #------------------------------------
  echo "==> [grep-pass1] Rodando ./configure..."
  CFLAGS="$CFLAGS_GREP" \
  ./configure \
    --prefix=/usr \
    $HOST_OPTS

  echo "==> [grep-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [grep-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [grep-pass1] make concluído"

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
  # echo "==> [grep-pass1] Rodando test suite (opcional)..."
  # make check || true

  #------------------------------------
  # Instalação em $LFS via DESTDIR do adm
  #------------------------------------
  echo "==> [grep-pass1] Instalando em DESTDIR=${DESTDIR}${LFS}"
  mkdir -p "$DESTDIR$LFS"
  make DESTDIR="$DESTDIR$LFS" install

  echo "==> [grep-pass1] Grep-${PKG_VERSION} instalado em $DESTDIR$LFS/usr"

  #------------------------------------
  # Pós-instalação mínima
  #
  # Nada especial é necessário aqui para o Pass1.
  # Se quiser remover docs extras ou exemplos, pode fazê-lo
  # respeitando seu layout de sistema.
  #------------------------------------
  echo "==> [grep-pass1] Build do Grep-${PKG_VERSION} Pass 1 finalizado com sucesso."
}
