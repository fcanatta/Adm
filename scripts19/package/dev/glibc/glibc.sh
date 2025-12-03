#!/usr/bin/env bash
# Script de construção do Glibc para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/libs/glibc/glibc.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball
#   DESTDIR  : raiz de instalação temporária (pkgroot)
#   PROFILE  : glibc / musl / outro (string)
#   NUMJOBS  : número de jobs para o make
#
# Este script deve definir:
#   PKG_VERSION
#   SRC_URL
#   (opcional) SRC_MD5
#   função pkg_build()
#
# OBS:
#   - Glibc 2.42 pede GCC >= 12.1 e Binutils >= 2.39 para compilar. 5
#   - Pressupõe headers de kernel já instalados em /usr/include.

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="2.42"
SRC_URL="https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4/glibc-${PKG_VERSION}.tar.xz"
# ou, se preferir, use o ftp.gnu.org:
# SRC_URL="https://ftp.gnu.org/gnu/glibc/glibc-${PKG_VERSION}.tar.xz"
# SRC_MD5 opcional:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [glibc] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS : ${NUMJOBS:-1}"

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e flags
  # (glibc não precisa de nada muito maluco aqui)
  #------------------------------------
  local ARCH CFLAGS_GLIBC
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i386
      CFLAGS_GLIBC="-O2 -pipe"
      ;;
    x86_64)
      CFLAGS_GLIBC="-O2 -pipe -fno-omit-frame-pointer"
      ;;
    *)
      CFLAGS_GLIBC="-O2 -pipe"
      ;;
  esac

  echo "==> [glibc] ARCH   : $ARCH"
  echo "==> [glibc] CFLAGS : $CFLAGS_GLIBC"

  #------------------------------------
  # PROFILE (apenas informativo aqui)
  #------------------------------------
  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [glibc] PROFILE = glibc (esperado para esta libc)"
      ;;
    musl)
      echo "==> [glibc] PROFILE = musl, mas estamos construindo glibc."
      echo "                (provavelmente para um rootfs/chroot separado)."
      ;;
    *)
      echo "==> [glibc] PROFILE desconhecido (${PROFILE}), só informativo."
      ;;
  esac

  #------------------------------------
  # Aplicar patches recomendados pelo LFS
  #   - upstream_fixes-1: bugfixes da branch estável
  #   - fhs-1: ajustar programas que usariam /var/db para caminhos FHS
  #------------------------------------
  local PATCH_BASE="https://www.linuxfromscratch.org/patches/lfs/development"

  apply_patch_stream() {
    local url="$1"
    echo "==> [glibc] Baixando e aplicando patch: $url"
    if command -v curl >/dev/null 2>&1; then
      if ! curl -fsSL "$url" | patch -Np1; then
        echo "ERRO: falha ao aplicar patch de $url"
        exit 1
      fi
    elif command -v wget >/dev/null 2>&1; then
      if ! wget -qO- "$url" | patch -Np1; then
        echo "ERRO: falha ao aplicar patch de $url"
        exit 1
      fi
    else
      echo "ERRO: nem curl nem wget disponíveis para baixar patches."
      exit 1
    fi
  }

  # Patches do LFS 12.4 para glibc-2.42 6
  apply_patch_stream "${PATCH_BASE}/glibc-2.42-upstream_fixes-1.patch"
  apply_patch_stream "${PATCH_BASE}/glibc-2.42-fhs-1.patch"

  echo "==> [glibc] Patches upstream_fixes-1 e fhs-1 aplicados."

  #------------------------------------
  # Fix no stdlib/abort.c (Valgrind / BLFS) – igual ao LFS
  #------------------------------------
  echo "==> [glibc] Aplicando ajuste em stdlib/abort.c (Valgrind fix)"
  sed -e '/unistd.h/i #include <string.h>' \
      -e '/libc_rwlock_init/c\
  __libc_rwlock_define_initialized (, reset_lock);\
  memcpy (&lock, &reset_lock, sizeof (lock));' \
      -i stdlib/abort.c

  #------------------------------------
  # Diretório de build separado
  #------------------------------------
  echo "==> [glibc] Criando diretório de build"
  rm -rf build
  mkdir -p build
  cd build

  # Garante que ldconfig/sln vão para /usr/sbin dentro do DESTDIR 7
  echo "rootsbindir=/usr/sbin" > configparms

  #------------------------------------
  # Configure – baseado no LFS 12.4 (cap. 8.5) 8
  #------------------------------------
  echo "==> [glibc] Rodando configure"

  # Opcionalmente você pode ajustar enable-kernel conforme o mínimo
  # que seu sistema precisa suportar (aqui usando 5.4 como no LFS).
  CFLAGS="$CFLAGS_GLIBC" \
  ../configure \
    --prefix=/usr                   \
    --disable-werror                \
    --disable-nscd                  \
    libc_cv_slibdir=/usr/lib        \
    --enable-stack-protector=strong \
    --enable-kernel=5.4

  echo "==> [glibc] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [glibc] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [glibc] make concluído"

  #------------------------------------
  # Testes (opcional – MUITO pesados)
  #   Em LFS eles rodam 'make check' com várias variáveis de ambiente.
  #   Aqui deixo comentado pra não doer na primeira rodada.
  #------------------------------------
  # echo "==> [glibc] Rodando test suite (make check)..."
  # make check || true

  #------------------------------------
  # Instalação em DESTDIR
  #------------------------------------
  echo "==> [glibc] Instalando em DESTDIR=${DESTDIR}"
  make DESTDIR="$DESTDIR" install

  # OBS: Glibc normalmente instala:
  #   - libc.so.* em /usr/lib (por causa do libc_cv_slibdir)
  #   - loader ld-linux-*.so.* em /usr/lib ou /lib conforme config
  #   - ldconfig, sln em /usr/sbin (por causa do configparms)

  # Não fazemos strip em glibc aqui – deixar as libs intactas é mais
  # seguro para debug e para evitar quebrar recursos mais avançados.

  echo "==> [glibc] Build do glibc-${PKG_VERSION} finalizado com sucesso."
}
