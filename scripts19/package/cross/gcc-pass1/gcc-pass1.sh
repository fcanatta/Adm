#!/usr/bin/env bash
# Script de construção do GCC-15.2.0 - Pass 1 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/gcc-pass1/gcc-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball (gcc-15.2.0)
#   DESTDIR  : raiz de instalação temporária (pkgroot)
#   PROFILE  : glibc / musl / outro (aqui é só log; Pass 1 é libc-agnóstico)
#   NUMJOBS  : número de jobs para o make
#
# Este script deve definir:
#   PKG_VERSION
#   SRC_URL
#   (opcional) SRC_MD5
#   função pkg_build()
#
# OBS:
#   - Este é o GCC PASS 1 (cross-GCC), no estilo LFS 12.4. 
#   - Assume que LFS e LFS_TGT estão configurados:
#       export LFS=/mnt/lfs
#       export LFS_TGT=$(uname -m)-lfs-linux-gnu
#   - PREFIX é /tools (como no LFS), mas com DESTDIR:
#       arquivos vão para $DESTDIR/tools/...
#       quando o adm instalar o pacote (untar em /), o resultado final será /tools/...

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="15.2.0"
SRC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
# Se quiser usar o mirror do LFS:
# SRC_URL="https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4/gcc-${PKG_VERSION}.tar.xz"

pkg_build() {
  set -euo pipefail

  echo "==> [gcc-pass1] Build iniciado"
  echo "    Versão   : ${PKG_VERSION}"
  echo "    SRC_DIR  : ${SRC_DIR}"
  echo "    DESTDIR  : ${DESTDIR}"
  echo "    PROFILE  : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS  : ${NUMJOBS:-1}"

  #------------------------------------
  # Verificar ambiente LFS / LFS_TGT
  #------------------------------------
  if [ -z "${LFS:-}" ]; then
    echo "ERRO: variável de ambiente LFS não está definida."
    echo "      Exemplo: export LFS=/mnt/lfs"
    exit 1
  fi

  if [ -z "${LFS_TGT:-}" ]; then
    echo "ERRO: variável de ambiente LFS_TGT não está definida."
    echo "      Exemplo: export LFS_TGT=\$(uname -m)-lfs-linux-gnu"
    exit 1
  fi

  echo "==> [gcc-pass1] LFS     = $LFS"
  echo "==> [gcc-pass1] LFS_TGT = $LFS_TGT"

  cd "$SRC_DIR"

  #------------------------------------
  # Log do PROFILE (Pass 1 é agnóstico à libc)
  #------------------------------------
  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [gcc-pass1] PROFILE = glibc (ou vazio) – Pass 1 não depende da libc"
      ;;
    musl)
      echo "==> [gcc-pass1] PROFILE = musl – Pass 1 continua igual (cross-compiler sem libc)"
      ;;
    *)
      echo "==> [gcc-pass1] PROFILE desconhecido (${PROFILE}), apenas log"
      ;;
  esac

  #------------------------------------
  # Incluir MPFR, GMP, MPC dentro da árvore do GCC (estilo LFS) 
  #
  # O LFS faz (dentro do diretório do GCC):
  #   tar -xf ../mpfr-4.2.2.tar.xz  && mv -v mpfr-4.2.2 mpfr
  #   tar -xf ../gmp-6.3.0.tar.xz   && mv -v gmp-6.3.0  gmp
  #   tar -xf ../mpc-1.3.1.tar.gz   && mv -v mpc-1.3.1  mpc
  #
  # Aqui tentamos o mesmo *se* os tarballs estiverem um nível acima.
  # Se não tiverem, o GCC tenta usar as libs do sistema (gmp/mpfr/mpc)
  # que você já pode ter empacotado via adm.
  #------------------------------------
  if [ -f "../mpfr-4.2.2.tar.xz" ]; then
    echo "==> [gcc-pass1] Incorporando mpfr-4.2.2 ao source do GCC"
    tar -xf ../mpfr-4.2.2.tar.xz
    mv -v mpfr-4.2.2 mpfr
  else
    echo "==> [gcc-pass1] AVISO: ../mpfr-4.2.2.tar.xz não encontrado; usando mpfr do sistema (se disponível)."
  fi

  if [ -f "../gmp-6.3.0.tar.xz" ]; then
    echo "==> [gcc-pass1] Incorporando gmp-6.3.0 ao source do GCC"
    tar -xf ../gmp-6.3.0.tar.xz
    mv -v gmp-6.3.0 gmp
  else
    echo "==> [gcc-pass1] AVISO: ../gmp-6.3.0.tar.xz não encontrado; usando gmp do sistema (se disponível)."
  fi

  if [ -f "../mpc-1.3.1.tar.gz" ]; then
    echo "==> [gcc-pass1] Incorporando mpc-1.3.1 ao source do GCC"
    tar -xf ../mpc-1.3.1.tar.gz
    mv -v mpc-1.3.1 mpc
  else
    echo "==> [gcc-pass1] AVISO: ../mpc-1.3.1.tar.gz não encontrado; usando mpc do sistema (se disponível)."
  fi

  #------------------------------------
  # Ajuste em t-linux64 para lib em vez de lib64 (x86_64) 
  #------------------------------------
  case "$(uname -m)" in
    x86_64)
      echo "==> [gcc-pass1] Ajustando gcc/config/i386/t-linux64 (lib64 -> lib)"
      sed -e '/m64=/s/lib64/lib/' -i gcc/config/i386/t-linux64
      ;;
  esac

  #------------------------------------
  # Diretório de build dedicado
  #------------------------------------
  rm -rf build
  mkdir -p build
  cd build

  #------------------------------------
  # Configure (igual ao LFS, exceto prefix=/tools) 
  #
  # ../configure                  \
  #     --target=$LFS_TGT         \
  #     --prefix=$LFS/tools       \
  #     --with-glibc-version=2.42 \
  #     --with-sysroot=$LFS       \
  #     --with-newlib             \
  #     --without-headers         \
  #     --enable-default-pie      \
  #     --enable-default-ssp      \
  #     --disable-nls             \
  #     --disable-shared          \
  #     --disable-multilib        \
  #     --disable-threads         \
  #     --disable-libatomic       \
  #     --disable-libgomp         \
  #     --disable-libquadmath     \
  #     --disable-libssp          \
  #     --disable-libvtv          \
  #     --disable-libstdcxx       \
  #     --enable-languages=c,c++
  #
  # Aqui usamos prefix=/tools para que, com DESTDIR, os arquivos vão
  # pra $DESTDIR/tools. Depois, quando o adm instalar o pacote no /,
  # o prefix final será /tools (igual ao plano do LFS para toolchain).
  #------------------------------------
  ../configure                  \
    --target="$LFS_TGT"         \
    --prefix=/tools             \
    --with-glibc-version=2.42   \
    --with-sysroot="$LFS"       \
    --with-newlib               \
    --without-headers           \
    --enable-default-pie        \
    --enable-default-ssp        \
    --disable-nls               \
    --disable-shared            \
    --disable-multilib          \
    --disable-threads           \
    --disable-libatomic         \
    --disable-libgomp           \
    --disable-libquadmath       \
    --disable-libssp            \
    --disable-libvtv            \
    --disable-libstdcxx         \
    --enable-languages=c,c++

  echo "==> [gcc-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [gcc-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [gcc-pass1] make concluído"

  #------------------------------------
  # Instalação em DESTDIR
  #------------------------------------
  echo "==> [gcc-pass1] Instalando em DESTDIR=${DESTDIR}"
  make DESTDIR="$DESTDIR" install
  echo "==> [gcc-pass1] make install concluído em $DESTDIR"

  #------------------------------------
  # Criar header interno completo limits.h (estilo LFS) 
  #
  # No LFS, é:
  #   cd ..
  #   cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
  #     `dirname $($LFS_TGT-gcc -print-libgcc-file-name)`/include/limits.h
  #
  # Aqui, para não depender de rodar o $LFS_TGT-gcc de dentro do DESTDIR,
  # descobrimos a pasta via árvore de arquivos em $DESTDIR/tools/lib/gcc/$LFS_TGT.
  #------------------------------------
  cd "$SRC_DIR"

  local GCC_TARGET_LIB_BASE GCC_TARGET_VER GCC_TARGET_INC_DIR
  GCC_TARGET_LIB_BASE="$DESTDIR/tools/lib/gcc/$LFS_TGT"

  if [ -d "$GCC_TARGET_LIB_BASE" ]; then
    # Deve haver um único subdiretório com a versão (ex.: 15.2.0)
    GCC_TARGET_VER="$(cd "$GCC_TARGET_LIB_BASE" && echo *)"
    GCC_TARGET_INC_DIR="$GCC_TARGET_LIB_BASE/$GCC_TARGET_VER/include"

    echo "==> [gcc-pass1] Criando limits.h em $GCC_TARGET_INC_DIR"
    mkdir -p "$GCC_TARGET_INC_DIR"

    cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
      "$GCC_TARGET_INC_DIR/limits.h"
  else
    echo "AVISO: diretório $GCC_TARGET_LIB_BASE não encontrado."
    echo "       limits.h interno não foi gerado; verifique se make install funcionou."
  fi

  echo "==> [gcc-pass1] Build do GCC-${PKG_VERSION} - Pass 1 finalizado com sucesso."
}
