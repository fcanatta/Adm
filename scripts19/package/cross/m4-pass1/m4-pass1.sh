#!/usr/bin/env bash
# Script de construção do M4-1.4.20 - Pass 1 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/m4-pass1/m4-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball (m4-1.4.20)
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
#   - "Pass 1" aqui significa que o m4 será instalado dentro do sysroot $LFS,
#     igual glibc-pass1, libstdcxx-pass1, etc.
#   - Se LFS_TGT estiver definido, usamos --host=$LFS_TGT e --build=... para
#     cruzar m4 para o alvo do LFS; se não, compilamos nativo e só instalamos
#     sob $LFS/usr (caso de você rodar dentro de um chroot já).

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="1.4.20"
SRC_URL="https://ftp.gnu.org/gnu/m4/m4-${PKG_VERSION}.tar.xz"
# Opcional:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [m4-pass1] Build iniciado"
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

  echo "==> [m4-pass1] LFS = ${LFS}"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [m4-pass1] PROFILE = glibc (ou vazio) – m4 é agnóstico de libc, só log."
      ;;
    musl)
      echo "==> [m4-pass1] PROFILE = musl – idem, m4 não muda; só indicativo de que o sysroot $LFS é musl."
      ;;
    *)
      echo "==> [m4-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e flags
  #------------------------------------
  local ARCH CFLAGS_M4
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i386
      CFLAGS_M4="-O2 -pipe"
      ;;
    x86_64)
      CFLAGS_M4="-O2 -pipe"
      ;;
    *)
      CFLAGS_M4="-O2 -pipe"
      ;;
  esac

  echo "==> [m4-pass1] ARCH   : $ARCH"
  echo "==> [m4-pass1] CFLAGS : $CFLAGS_M4"

  #------------------------------------
  # Definir opções de cross (se LFS_TGT existir)
  #------------------------------------
  local HOST_OPTS
  HOST_OPTS=""

  if [ -n "${LFS_TGT:-}" ]; then
    echo "==> [m4-pass1] LFS_TGT = ${LFS_TGT} (vamos configurar --host=$LFS_TGT)"
    # m4 usa build-aux/config.guess nas versões modernas
    if [ -x "./build-aux/config.guess" ]; then
      local BUILD_TRIPLET
      BUILD_TRIPLET="$(./build-aux/config.guess)"
      HOST_OPTS="--host=${LFS_TGT} --build=${BUILD_TRIPLET}"
      echo "==> [m4-pass1] BUILD triplet detectado: ${BUILD_TRIPLET}"
    else
      echo "AVISO: build-aux/config.guess não encontrado; usando apenas --host=${LFS_TGT}"
      HOST_OPTS="--host=${LFS_TGT}"
    fi
  else
    echo "==> [m4-pass1] LFS_TGT não definido; configurando m4 como nativo para o ambiente atual."
  fi

  #------------------------------------
  # Configure
  #
  # Para Pass1, queremos m4 instalado em $LFS/usr/bin, etc.
  # então usamos:
  #   --prefix=/usr
  # e na instalação:
  #   DESTDIR="$DESTDIR$LFS"
  #------------------------------------
  echo "==> [m4-pass1] Rodando ./configure"
  CFLAGS="$CFLAGS_M4" \
  ./configure \
    --prefix=/usr \
    $HOST_OPTS

  echo "==> [m4-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [m4-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [m4-pass1] make concluído"

  # Testes (opcionais; podem ser demorados e usar recursos não disponíveis
  # em ambiente cross). Se quiser rodar:
  #   make check
  # Aqui deixo comentado:
  # echo "==> [m4-pass1] Rodando test suite (opcional)..."
  # make check || true

  #------------------------------------
  # Instalar em $LFS via DESTDIR do adm
  #------------------------------------
  echo "==> [m4-pass1] Instalando em DESTDIR=${DESTDIR}${LFS}"
  mkdir -p "$DESTDIR$LFS"
  make DESTDIR="$DESTDIR$LFS" install

  echo "==> [m4-pass1] m4-${PKG_VERSION} instalado em $DESTDIR$LFS/usr"

  #------------------------------------
  # Pós-instalação mínima
  #
  # - M4 não instala libs compartilhadas críticas; é basicamente o binário m4
  #   e manpages. Se você quiser limpar /usr/share/info ou algo assim,
  #   pode fazer aqui.
  #------------------------------------
  echo "==> [m4-pass1] Build do M4-${PKG_VERSION} Pass 1 finalizado com sucesso."
}
