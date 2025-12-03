#!/usr/bin/env bash
# Script de construção do Findutils-4.10.0 - Pass 1 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/findutils-pass1/findutils-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball (findutils-4.10.0)
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
# Baseado no fluxo típico do LFS:
#   ./configure --prefix=/usr \
#               --localstatedir=/var/lib/locate \
#               --host=$LFS_TGT --build=$(build-aux/config.guess)
#   make
#   make DESTDIR=$LFS install
#
# Aqui adaptado para o adm usando DESTDIR="$DESTDIR$LFS" como sysroot.

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="4.10.0"
SRC_URL="https://ftp.gnu.org/gnu/findutils/findutils-${PKG_VERSION}.tar.xz"
# Se quiser, preencha o MD5:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [findutils-pass1] Build iniciado"
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

  echo "==> [findutils-pass1] LFS = ${LFS}"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [findutils-pass1] PROFILE = glibc (ou vazio) – apenas informativo."
      ;;
    musl)
      echo "==> [findutils-pass1] PROFILE = musl – findutils não muda, só log."
      ;;
    *)
      echo "==> [findutils-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e CFLAGS
  #------------------------------------
  local ARCH CFLAGS_FIND
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i386
      CFLAGS_FIND="-O2 -pipe"
      ;;
    x86_64)
      CFLAGS_FIND="-O2 -pipe"
      ;;
    *)
      CFLAGS_FIND="-O2 -pipe"
      ;;
  esac

  echo "==> [findutils-pass1] ARCH   : $ARCH"
  echo "==> [findutils-pass1] CFLAGS : $CFLAGS_FIND"

  #------------------------------------
  # Opções de host/build (cross ou nativo)
  #------------------------------------
  local HOST_OPTS=""
  if [ -n "${LFS_TGT:-}" ]; then
    echo "==> [findutils-pass1] LFS_TGT = ${LFS_TGT} (cross)"
    if [ -x "./build-aux/config.guess" ]; then
      local BUILD_TRIPLET
      BUILD_TRIPLET="$(./build-aux/config.guess)"
      HOST_OPTS="--host=${LFS_TGT} --build=${BUILD_TRIPLET}"
      echo "==> [findutils-pass1] BUILD triplet detectado: ${BUILD_TRIPLET}"
    else
      echo "AVISO: build-aux/config.guess não encontrado; usando apenas --host=${LFS_TGT}"
      HOST_OPTS="--host=${LFS_TGT}"
    fi
  else
    echo "==> [findutils-pass1] LFS_TGT não definido; build nativo para o ambiente atual."
  fi

  #------------------------------------
  # Configure
  #
  # Para Pass 1, findutils vai para $LFS/usr,
  # então usamos --prefix=/usr e localstatedir correto.
  #------------------------------------
  echo "==> [findutils-pass1] Rodando ./configure..."
  CFLAGS="$CFLAGS_FIND" \
  ./configure \
    --prefix=/usr \
    --localstatedir=/var/lib/locate \
    $HOST_OPTS

  echo "==> [findutils-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [findutils-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [findutils-pass1] make concluído"

  #------------------------------------
  # Testes (opcionais)
  #
  # Em ambiente cross, geralmente os testes são pulados.
  # Se estiver num chroot já dentro do $LFS, pode habilitar:
  #
  #   make check
  #
  #------------------------------------
  # echo "==> [findutils-pass1] Rodando test suite (opcional)..."
  # make check || true

  #------------------------------------
  # Instalação em $LFS via DESTDIR do adm
  #------------------------------------
  echo "==> [findutils-pass1] Instalando em DESTDIR=${DESTDIR}${LFS}"
  mkdir -p "$DESTDIR$LFS"
  make DESTDIR="$DESTDIR$LFS" install

  echo "==> [findutils-pass1] Findutils-${PKG_VERSION} instalado em $DESTDIR$LFS/usr"

  #------------------------------------
  # Pós-instalação mínima
  #
  # Aqui normalmente não há hacks especiais no Pass 1.
  # Se quiser remover docs/infos, faça aqui conforme seu layout.
  #------------------------------------
  echo "==> [findutils-pass1] Build do Findutils-${PKG_VERSION} Pass 1 finalizado com sucesso."
}
