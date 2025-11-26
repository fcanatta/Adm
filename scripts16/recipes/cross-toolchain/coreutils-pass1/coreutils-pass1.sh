#!/usr/bin/env bash
# Coreutils-9.9 — LFS Chapter 6.5 (Temporary Tools)
# Baseado em:
#   - LFS dev 12.4, seção 3.2 (pacotes)
#   - Multilib LFS ml-12.4-102, 6.5. Coreutils-9.9

PKG_NAME="coreutils-pass1"
PKG_VERSION="9.9"
PKG_RELEASE="1"

PKG_DESC="GNU Coreutils ${PKG_VERSION} - utilitários básicos do sistema (ferramenta temporária cross)"
PKG_LICENSE="GPL-3.0-or-later"
PKG_URL="https://www.gnu.org/software/coreutils/"
PKG_GROUPS="cross-toolchain"

# Dependências lógicas para ordenação (toolchain + básicas já feitas)
PKG_DEPENDS="binutils-pass1 gcc-pass1 linux-headers glibc-pass1 gcc-libstdc++ m4-pass1 ncurses-pass1 bash-pass1"

# Pacote conforme LFS dev 12.4, seção 3.2
# Download: https://ftp.gnu.org/gnu/coreutils/coreutils-9.9.tar.xz
# MD5: ce613d0dae179f4171966ecd0a898ec4
PKG_SOURCES="https://ftp.gnu.org/gnu/coreutils/coreutils-${PKG_VERSION}.tar.xz"
PKG_MD5SUM="ce613d0dae179f4171966ecd0a898ec4"
PKG_SHA256SUM=""

# Para temporary tools não queremos upgrade automático
pkg_upstream_version() {
  printf '%s\n' "${PKG_VERSION}"
}

# -------------------------------------------------------------
# prepare(): só garante que o ambiente LFS está ok
# -------------------------------------------------------------
pkg_prepare() {
  : "${LFS:?Variável LFS não definida. Exporte LFS=/mnt/lfs (por exemplo)}"
  : "${LFS_TGT:?Variável LFS_TGT não definida. Ex: x86_64-lfs-linux-gnu}"
}

# -------------------------------------------------------------
# build()
# LFS (multilib ml-12.4-102) manda:
#   ./configure --prefix=/usr                     \
#               --host=$LFS_TGT                   \
#               --build=$(build-aux/config.guess) \
#               --enable-install-program=hostname \
#               --enable-no-install-program=kill,uptime
#   make
# -------------------------------------------------------------
pkg_build() {
  : "${LFS:?Variável LFS não definida}"
  : "${LFS_TGT:?Variável LFS_TGT não definida}"

  ./configure --prefix=/usr                     \
              --host="$LFS_TGT"                 \
              --build="$(build-aux/config.guess)" \
              --enable-install-program=hostname \
              --enable-no-install-program=kill,uptime

  make
}

# -------------------------------------------------------------
# check(): LFS não roda testes para Coreutils em Chapter 6
# -------------------------------------------------------------
pkg_check() {
  :
}

# -------------------------------------------------------------
# install()
# LFS manda:
#   make DESTDIR=$LFS install
#   mv -v $LFS/usr/bin/chroot              $LFS/usr/sbin
#   mkdir -pv $LFS/usr/share/man/man8
#   mv -v $LFS/usr/share/man/man1/chroot.1 $LFS/usr/share/man/man8/chroot.8
#   sed -i 's/"1"/"8"/'                    $LFS/usr/share/man/man8/chroot.8
#
# Aqui adaptamos para o esquema do adm:
#   DESTDIR = ${PKG_DESTDIR}${LFS}
# -------------------------------------------------------------
pkg_install() {
  : "${LFS:?Variável LFS não definida}"
  : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"

  # Instala tudo no staging do adm apontando para o sysroot $LFS
  make DESTDIR="${PKG_DESTDIR}${LFS}" install

  # Agora ajusta chroot e sua manpage dentro do staging
  # mv -v $LFS/usr/bin/chroot $LFS/usr/sbin
  mkdir -pv "${PKG_DESTDIR}${LFS}/usr/sbin"
  if [[ -x "${PKG_DESTDIR}${LFS}/usr/bin/chroot" ]]; then
    mv -v "${PKG_DESTDIR}${LFS}/usr/bin/chroot" \
          "${PKG_DESTDIR}${LFS}/usr/sbin"
  fi

  # man8/chroot.8
  mkdir -pv "${PKG_DESTDIR}${LFS}/usr/share/man/man8"
  if [[ -f "${PKG_DESTDIR}${LFS}/usr/share/man/man1/chroot.1" ]]; then
    mv -v "${PKG_DESTDIR}${LFS}/usr/share/man/man1/chroot.1" \
          "${PKG_DESTDIR}${LFS}/usr/share/man/man8/chroot.8"

    sed -i 's/"1"/"8"/' \
      "${PKG_DESTDIR}${LFS}/usr/share/man/man8/chroot.8"
  fi
}
