#!/usr/bin/env bash
# Script de construção do Linux API Headers para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/kernel/linux-headers/linux-headers.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball (linux-6.17.9)
#   DESTDIR  : raiz de instalação temporária (pkgroot)
#   PROFILE  : glibc / musl / outro (só informativo aqui)
#   NUMJOBS  : número de jobs para o make
#
# Este script deve definir:
#   PKG_VERSION
#   SRC_URL
#   função pkg_build()
#
# Este pacote instala apenas os Linux API headers em:
#   $DESTDIR/usr/include
# (igual ao capítulo "Linux API Headers" do LFS, adaptado para o adm)

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="6.17.9"

# Kernel.org segue o padrão v6.x:
#   https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.17.9.tar.xz
SRC_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"

#----------------------------------------
# Função principal de build
#----------------------------------------
pkg_build() {
  set -euo pipefail

  echo "==> [linux-headers] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS : ${NUMJOBS:-1}"

  cd "$SRC_DIR"

  #------------------------------------
  # Arquitetura (apenas informativo)
  #------------------------------------
  local ARCH
  ARCH="$(uname -m)"
  echo "==> [linux-headers] ARCH: $ARCH"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [linux-headers] PROFILE = glibc (ou vazio) – headers servem para ambas as libc."
      ;;
    musl)
      echo "==> [linux-headers] PROFILE = musl – headers são os mesmos, só mudam as libs."
      ;;
    *)
      echo "==> [linux-headers] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  #------------------------------------
  # Limpeza completa da árvore do kernel
  #   make mrproper
  #------------------------------------
  echo "==> [linux-headers] Rodando make mrproper"
  make mrproper

  #------------------------------------
  # Gerar Linux API Headers
  #   make headers
  #
  # Em LFS, o comando é:
  #   make headers
  #
  # Podemos passar -jNUMJOBS pra acelerar um pouco, mas
  # não é crítico; uso NUMJOBS mesmo assim.
  #------------------------------------
  echo "==> [linux-headers] Gerando headers (make headers)"
  make -j"${NUMJOBS:-1}" headers

  #------------------------------------
  # Limpar lixo e copiar usr/include -> $DESTDIR/usr/include
  #
  # Em LFS:
  #   find usr/include -name '.*' -delete
  #   rm usr/include/Makefile
  #   cp -rv usr/include/* /usr/include
  #------------------------------------
  echo "==> [linux-headers] Limpando arquivos indesejados em usr/include"
  find usr/include -name '.*' -delete || true
  rm -f usr/include/Makefile || true

  echo "==> [linux-headers] Instalando headers em $DESTDIR/usr/include"
  mkdir -p "$DESTDIR/usr/include"
  cp -rv usr/include/* "$DESTDIR/usr/include/"

  echo "==> [linux-headers] Linux API Headers ${PKG_VERSION} instalados em $DESTDIR/usr/include"
  echo "==> [linux-headers] Build finalizado com sucesso."
}
