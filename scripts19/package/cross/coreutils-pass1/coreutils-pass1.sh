#!/usr/bin/env bash
# Script de construção do Coreutils-9.9 - Pass 1 (temporary tools) para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/coreutils-pass1/coreutils-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído (coreutils-9.9)
#   DESTDIR  : raiz de instalação temporária (pkgroot do pacote)
#   PROFILE  : glibc / musl / outro (aqui é só log)
#   NUMJOBS  : número de jobs para o make
#
# Ambiente LFS (como pros outros *-pass1*):
#   export LFS=/mnt/lfs
#   export LFS_TGT=$(uname -m)-lfs-linux-gnu
#
# LFS (Cap. 6, Coreutils-9.9) faz: 
#   ./configure --prefix=/usr                     \
#               --host=$LFS_TGT                   \
#               --build=$(build-aux/config.guess) \
#               --enable-install-program=hostname \
#               --enable-no-install-program=kill,uptime
#   make
#   make DESTDIR=$LFS install
#   mv -v $LFS/usr/bin/chroot              $LFS/usr/sbin
#   mkdir -pv $LFS/usr/share/man/man8
#   mv -v $LFS/usr/share/man/man1/chroot.1 $LFS/usr/share/man/man8/chroot.8
#   sed -i 's/"1"/"8"/'                    $LFS/usr/share/man/man8/chroot.8
#
# Aqui adaptamos para o adm:
#   - make DESTDIR="$DESTDIR$LFS" install
#   - fazemos os mv/sed dentro de "$DESTDIR$LFS"
#   - assim o pacote tem caminhos relativos corretos e as permissões/manpages
#     ficam certas quando o adm instalar.

PKG_VERSION="9.9"
SRC_URL="https://ftp.gnu.org/gnu/coreutils/coreutils-${PKG_VERSION}.tar.xz"
# Se quiser, adicione checksum oficial:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [coreutils-pass1] Build iniciado"
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

  echo "==> [coreutils-pass1] LFS     = $LFS"
  echo "==> [coreutils-pass1] LFS_TGT = $LFS_TGT"

  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [coreutils-pass1] PROFILE = glibc (ou vazio) – segue receita LFS."
      ;;
    musl)
      echo "==> [coreutils-pass1] PROFILE = musl – info apenas; este Pass1 é pro sysroot glibc em $LFS."
      ;;
    *)
      echo "==> [coreutils-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  # Pequenina sanity-check no source
  if [ ! -d "src" ] || [ ! -f "src/ls.c" ]; then
    echo "ERRO: SRC_DIR não parece ser um source de coreutils (faltam src/ ou src/ls.c)."
    exit 1
  fi

  #------------------------------------
  # Configure (igual ao livro) 
  #------------------------------------
  echo "==> [coreutils-pass1] Rodando ./configure"

  ./configure \
    --prefix=/usr                     \
    --host="$LFS_TGT"                 \
    --build="$(build-aux/config.guess)" \
    --enable-install-program=hostname \
    --enable-no-install-program=kill,uptime

  echo "==> [coreutils-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [coreutils-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [coreutils-pass1] make concluído"

  #------------------------------------
  # Instalar em $LFS via DESTDIR do adm
  #
  # LFS:
  #   make DESTDIR=$LFS install
  #
  # Aqui:
  #   make DESTDIR="$DESTDIR$LFS" install
  #
  # O pacote terá caminhos tipo "mnt/lfs/usr/bin/ls", etc.
  # Quando o adm instalar o pacote, isso vira /mnt/lfs/usr/bin/ls
  # com as permissões padrão corretas de coreutils.
  #------------------------------------
  local ROOT
  ROOT="$DESTDIR$LFS"

  echo "==> [coreutils-pass1] Instalando em ROOT=${ROOT}"
  mkdir -p "$ROOT"
  make DESTDIR="$ROOT" install

  #------------------------------------
  # Ajustes pós-instalação (chroot e manpage)
  #   - mover chroot para /usr/sbin
  #   - mover manpage para seção 8
  #   - ajustar o "1" -> "8" dentro do arquivo
  # Isso garante local e seção corretos (como no LFS) já no pacote.
  #------------------------------------
  echo "==> [coreutils-pass1] Ajustando chroot e manpage para seção 8"

  local BIN_CHROOT MAN1_CHROOT MAN8_DIR

  BIN_CHROOT="$ROOT/usr/bin/chroot"
  MAN1_CHROOT="$ROOT/usr/share/man/man1/chroot.1"
  MAN8_DIR="$ROOT/usr/share/man/man8"

  if [ -x "$BIN_CHROOT" ]; then
    mkdir -p "$ROOT/usr/sbin"
    mv -v "$BIN_CHROOT" "$ROOT/usr/sbin/chroot"
  else
    echo "AVISO: $BIN_CHROOT não encontrado executável; verifique build de coreutils."
  fi

  mkdir -p "$MAN8_DIR"

  if [ -f "$MAN1_CHROOT" ]; then
    mv -v "$MAN1_CHROOT" "$MAN8_DIR/chroot.8"
    sed -i 's/"1"/"8"/' "$MAN8_DIR/chroot.8" || true
  else
    echo "AVISO: manpage $MAN1_CHROOT não encontrada; verifique instalação de manpages."
  fi

  echo "==> [coreutils-pass1] Coreutils-${PKG_VERSION} Pass 1 instalado em $ROOT"
  echo "==> [coreutils-pass1] Build concluído com sucesso."
}
