#!/usr/bin/env bash
# Script de construção do Bash-5.3 - Pass 1 (temporary tools) para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/bash-pass1/bash-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído (bash-5.3)
#   DESTDIR  : raiz de instalação temporária (pkgroot do pacote)
#   PROFILE  : glibc / musl / outro (aqui é só log)
#   NUMJOBS  : número de jobs para o make
#
# Ambiente LFS (igual ao resto dos *-pass1 / chapter06):
#   export LFS=/mnt/lfs
#   export LFS_TGT=$(uname -m)-lfs-linux-gnu
#
# O que este script faz (como no LFS 12.4, seção Bash-5.3): 
#   - ./configure --prefix=/usr --build=$(sh support/config.guess) \
#                 --host=$LFS_TGT --without-bash-malloc
#   - make
#   - make DESTDIR=$LFS install
#   - ln -sv bash $LFS/bin/sh
#
# Adaptado pro adm:
#   - make DESTDIR="$DESTDIR$LFS" install
#   - ln -sv bash "$DESTDIR$LFS/bin/sh"

PKG_VERSION="5.3"
SRC_URL="https://ftp.gnu.org/gnu/bash/bash-${PKG_VERSION}.tar.gz"
# Se quiser, adicione checksum:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [bash-pass1] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS : ${NUMJOBS:-1}"

  #------------------------------------
  # Checagem de ambiente LFS / LFS_TGT
  #------------------------------------
  if [ -z "${LFS:-}" ]; then
    echo "ERRO: variável LFS não está definida (ex: /mnt/lfs)."
    exit 1
  fi
  if [ -z "${LFS_TGT:-}" ]; then
    echo "ERRO: variável LFS_TGT não está definida (ex: \$(uname -m)-lfs-linux-gnu)."
    exit 1
  fi

  echo "==> [bash-pass1] LFS     = $LFS"
  echo "==> [bash-pass1] LFS_TGT = $LFS_TGT"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [bash-pass1] PROFILE = glibc (ou vazio) – build segue exatamente o LFS."
      ;;
    musl)
      echo "==> [bash-pass1] PROFILE = musl – info apenas, tool temporário pro sysroot $LFS."
      ;;
    *)
      echo "==> [bash-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  #------------------------------------
  # Configure (como no livro) 
  #------------------------------------
  echo "==> [bash-pass1] Rodando ./configure"

  ./configure \
    --prefix=/usr \
    --build="$(sh support/config.guess)" \
    --host="$LFS_TGT" \
    --without-bash-malloc

  echo "==> [bash-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [bash-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [bash-pass1] make concluído"

  #------------------------------------
  # Instalar em $LFS via DESTDIR do adm
  #
  # LFS:
  #   make DESTDIR=$LFS install
  #
  # Aqui:
  #   make DESTDIR="$DESTDIR$LFS" install
  #
  # O pacote vai ter caminhos "mnt/lfs/usr/bin/bash", etc., e quando o
  # adm instalar o tarball em /, isso vira /mnt/lfs/usr/bin/bash.
  #------------------------------------
  echo "==> [bash-pass1] Instalando em DESTDIR=${DESTDIR}${LFS}"
  mkdir -p "$DESTDIR$LFS"
  make DESTDIR="$DESTDIR$LFS" install

  #------------------------------------
  # Link /bin/sh -> bash dentro do sysroot
  #
  # LFS:
  #   ln -sv bash $LFS/bin/sh
  #
  # Aqui:
  #   ln -sv bash "$DESTDIR$LFS/bin/sh"
  #
  # Obs: em LFS, /mnt/lfs/bin é symlink pra usr/bin criado no cap. 4,
  # então o link "sh" aponta pra "bash" que está em /usr/bin.
  #------------------------------------
  echo "==> [bash-pass1] Criando link $LFS/bin/sh -> bash (via DESTDIR)"
  mkdir -p "$DESTDIR$LFS/bin"
  ln -sfv bash "$DESTDIR$LFS/bin/sh"

  echo "==> [bash-pass1] Bash-${PKG_VERSION} Pass 1 instalado em $DESTDIR$LFS"
  echo "==> [bash-pass1] Build concluído com sucesso."
}
