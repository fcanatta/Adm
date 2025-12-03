#!/usr/bin/env bash
# Script de construção do Diffutils-3.12 - Pass 1 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/diffutils-pass1/diffutils-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball (diffutils-3.12)
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
# OBS:
#   - "Pass 1" aqui significa que o diffutils será instalado dentro do sysroot $LFS,
#     como parte do ambiente de ferramentas (toolchain) que vive em $LFS.
#   - Se LFS_TGT estiver definido, usamos --host=$LFS_TGT e --build=... para
#     cruzar diffutils para o alvo do LFS; se não, compilamos nativo e apenas
#     instalamos sob $LFS/usr (caso de você rodar dentro de um chroot, por exemplo).

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="3.12"
SRC_URL="https://ftp.gnu.org/gnu/diffutils/diffutils-${PKG_VERSION}.tar.xz"
# Opcional (preencha se quiser checar integridade):
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [diffutils-pass1] Build iniciado"
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

  echo "==> [diffutils-pass1] LFS = ${LFS}"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [diffutils-pass1] PROFILE = glibc (ou vazio) – diffutils é agnóstico de libc, apenas log."
      ;;
    musl)
      echo "==> [diffutils-pass1] PROFILE = musl – idem, diffutils não muda; só indicativo de que o sysroot $LFS usa musl."
      ;;
    *)
      echo "==> [diffutils-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e flags
  #------------------------------------
  local ARCH CFLAGS_DIFF
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i386
      CFLAGS_DIFF="-O2 -pipe"
      ;;
    x86_64)
      CFLAGS_DIFF="-O2 -pipe"
      ;;
    *)
      CFLAGS_DIFF="-O2 -pipe"
      ;;
  esac

  echo "==> [diffutils-pass1] ARCH   : $ARCH"
  echo "==> [diffutils-pass1] CFLAGS : $CFLAGS_DIFF"

  #------------------------------------
  # Definir opções de cross (se LFS_TGT existir)
  #------------------------------------
  local HOST_OPTS
  HOST_OPTS=""

  if [ -n "${LFS_TGT:-}" ]; then
    echo "==> [diffutils-pass1] LFS_TGT = ${LFS_TGT} (vamos configurar --host=$LFS_TGT)"
    # diffutils também usa config.guess em build-aux nas versões modernas
    if [ -x "./build-aux/config.guess" ]; then
      local BUILD_TRIPLET
      BUILD_TRIPLET="$(./build-aux/config.guess)"
      HOST_OPTS="--host=${LFS_TGT} --build=${BUILD_TRIPLET}"
      echo "==> [diffutils-pass1] BUILD triplet detectado: ${BUILD_TRIPLET}"
    else
      echo "AVISO: build-aux/config.guess não encontrado; usando apenas --host=${LFS_TGT}"
      HOST_OPTS="--host=${LFS_TGT}"
    fi
  else
    echo "==> [diffutils-pass1] LFS_TGT não definido; configurando diffutils como nativo para o ambiente atual."
  fi

  #------------------------------------
  # Configure
  #
  # Para Pass1, queremos diffutils instalado em $LFS/usr/bin, etc.
  # então usamos:
  #   --prefix=/usr
  # e na instalação:
  #   DESTDIR="$DESTDIR$LFS"
  #------------------------------------
  echo "==> [diffutils-pass1] Rodando ./configure"
  CFLAGS="$CFLAGS_DIFF" \
  ./configure \
    --prefix=/usr \
    $HOST_OPTS

  echo "==> [diffutils-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [diffutils-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [diffutils-pass1] make concluído"

  #------------------------------------
  # Testes (opcionais)
  #
  # Em ambiente cross (LFS_TGT definido), normalmente os testes são
  # desabilitados ou ignorados, porque podem depender do host.
  #
  # Se você estiver num chroot nativo já dentro do $LFS, pode habilitar:
  #
  #   make check
  #
  # Aqui deixo comentado por segurança:
  #------------------------------------
  # echo "==> [diffutils-pass1] Rodando test suite (opcional)..."
  # make check || true

  #------------------------------------
  # Instalar em $LFS via DESTDIR do adm
  #------------------------------------
  echo "==> [diffutils-pass1] Instalando em DESTDIR=${DESTDIR}${LFS}"
  mkdir -p "$DESTDIR$LFS"
  make DESTDIR="$DESTDIR$LFS" install

  echo "==> [diffutils-pass1] diffutils-${PKG_VERSION} instalado em $DESTDIR$LFS/usr"

  #------------------------------------
  # Pós-instalação mínima
  #
  # - Diffutils instala binários como diff, cmp, sdiff, etc.,
  #   manpages e docs. Se você quiser limpar coisas específicas
  #   (ex: info, doc), pode fazer aqui, respeitando seu layout.
  #------------------------------------
  echo "==> [diffutils-pass1] Build do Diffutils-${PKG_VERSION} Pass 1 finalizado com sucesso."
}
