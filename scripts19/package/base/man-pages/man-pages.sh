#!/usr/bin/env bash
# Script de construção do Linux man-pages para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/base/man-pages/man-pages.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball
#   DESTDIR  : raiz de instalação temporária (pkgroot)
#   PROFILE  : glibc / musl / outro (string)  -> aqui é só informativo
#   NUMJOBS  : número de jobs para o make     -> quase não usamos aqui
#
# Este script deve definir:
#   PKG_VERSION
#   SRC_URL
#   (opcional) SRC_MD5
#   função pkg_build()

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="6.16"
# Tarball oficial no kernel.org:
# https://www.kernel.org/pub/linux/docs/man-pages/
SRC_URL="https://www.kernel.org/pub/linux/docs/man-pages/man-pages-${PKG_VERSION}.tar.xz"
# Se quiser validar integridade, pegue o checksum oficial e set:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [man-pages] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS : ${NUMJOBS:-1}"

  cd "$SRC_DIR"

  #------------------------------------
  # Info de arquitetura (só pra log)
  #------------------------------------
  local ARCH
  ARCH="$(uname -m)"
  echo "==> [man-pages] ARCH: ${ARCH}"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [man-pages] PROFILE = glibc (ou vazio) – páginas valem pra qualquer libc, mas foco glibc."
      ;;
    musl)
      echo "==> [man-pages] PROFILE = musl – páginas também são úteis em ambiente musl."
      ;;
    *)
      echo "==> [man-pages] PROFILE desconhecido (${PROFILE}), somente informativo."
      ;;
  esac

  #------------------------------------
  # Passo LFS: remover man3/crypt*
  #   Libxcrypt fornece páginas melhores; então evitamos conflito.
  #   (Se no teu sistema não tiver libxcrypt, ainda assim é aceitável.)
  #------------------------------------
  if ls man3/crypt* >/dev/null 2>&1; then
    echo "==> [man-pages] Removendo man3/crypt* (conflito com libxcrypt)"
    rm -v man3/crypt* || true
  fi

  #------------------------------------
  # Instalação
  #
  # LFS faz:
  #   make -R GIT=false prefix=/usr install
  #
  # Aqui adicionamos DESTDIR para instalar dentro do pkgroot
  # do adm (sem sujar o sistema host).
  #
  #  -R        : desabilita variáveis builtin do make (o build system
  #              do man-pages não se dá bem com elas).
  #  GIT=false : evita spam de "git: command not found".
  #------------------------------------
  echo "==> [man-pages] Executando make install (com DESTDIR)"
  make -R GIT=false \
    prefix=/usr \
    DESTDIR="$DESTDIR" \
    install

  echo "==> [man-pages] Instalação concluída em $DESTDIR"

  #------------------------------------
  # Pós-instalação (opcional)
  #
  # Normalmente não é necessário strip/compress aqui, porque:
  #   - man costuma lidar bem com páginas não comprimidas;
  #   - se quiser compressão, você pode ter um passo global de gzip
  #     de manpages no teu sistema.
  #
  # Se quiser comprimir todas as manpages já no pacote, descomenta:
  #------------------------------------
  # if command -v gzip >/dev/null 2>&1; then
  #   if [ -d "$DESTDIR/usr/share/man" ]; then
  #     echo "==> [man-pages] Compactando manpages em usr/share/man"
  #     find "$DESTDIR/usr/share/man" -type f -name '*.[0-9]' -print0 2>/dev/null \
  #       | xargs -0r gzip -9
  #   fi
  # fi

  echo "==> [man-pages] Build do man-pages-${PKG_VERSION} finalizado com sucesso."
}
