#!/usr/bin/env bash
# Script de construção do musl libc - Pass 1 para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/cross/musl-pass1/musl-pass1.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball (musl-1.2.5)
#   DESTDIR  : raiz de instalação temporária (pkgroot)
#   PROFILE  : glibc / musl / outro
#   NUMJOBS  : número de jobs para o make
#
# Este script deve definir:
#   PKG_VERSION
#   SRC_URL
#   função pkg_build()
#
# OBS:
#   - Este é o "musl-pass1": instala a libc musl dentro do $LFS,
#     via DESTDIR="$DESTDIR$LFS", no estilo dos outros *-pass1.
#   - Aplica os dois patches de segurança de 2025-02-13 (openwall)
#     no iconv (EUC-KR e UTF-8 output hardening).
#   - Não faz sanity-check aqui: você pode criar um hook
#     musl-pass1.post_install se quiser algo similar ao glibc-pass1.

#----------------------------------------
# Versão e origem
#----------------------------------------
PKG_VERSION="1.2.5"
SRC_URL="https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"
# Se quiser, adicione SRC_MD5 conforme checksum oficial
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [musl-pass1] Build iniciado"
  echo "    Versão   : ${PKG_VERSION}"
  echo "    SRC_DIR  : ${SRC_DIR}"
  echo "    DESTDIR  : ${DESTDIR}"
  echo "    PROFILE  : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS  : ${NUMJOBS:-1}"

  #------------------------------------
  # Verifica LFS
  #------------------------------------
  if [ -z "${LFS:-}" ]; then
    echo "ERRO: variável de ambiente LFS não está definida."
    echo "      Exemplo: export LFS=/mnt/lfs-musl"
    exit 1
  fi

  echo "==> [musl-pass1] LFS = ${LFS}"

  case "${PROFILE:-}" in
    musl)
      echo "==> [musl-pass1] PROFILE = musl (esperado para esta libc)."
      ;;
    glibc|"")
      echo "==> [musl-pass1] PROFILE = glibc/vazio – ainda assim vamos instalar musl no sysroot $LFS."
      ;;
    *)
      echo "==> [musl-pass1] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e CFLAGS
  #------------------------------------
  local ARCH CFLAGS_MUSL
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i386
      CFLAGS_MUSL="-O2 -pipe"
      ;;
    x86_64)
      CFLAGS_MUSL="-O2 -pipe -fPIC"
      ;;
    *)
      CFLAGS_MUSL="-O2 -pipe"
      ;;
  esac

  echo "==> [musl-pass1] ARCH   : $ARCH"
  echo "==> [musl-pass1] CFLAGS : $CFLAGS_MUSL"

  #------------------------------------
  # Aplicar patches de segurança do iconv (openwall, 2025-02-13)
  #   1) EUC-KR decoder fix
  #   2) UTF-8 output hardening
  #
  # URLs exatos:
  #   https://www.openwall.com/lists/musl/2025/02/13/1/1
  #   https://www.openwall.com/lists/musl/2025/02/13/1/2
  #------------------------------------
  echo "==> [musl-pass1] Aplicando patches de segurança (iconv)"

  apply_patch_stream() {
    local url="$1"
    echo "==> [musl-pass1] Baixando e aplicando patch: $url"
    if command -v curl >/dev/null 2>&1; then
      if ! curl -fsSL "$url" | patch -p1; then
        echo "ERRO: falha ao aplicar patch de $url"
        exit 1
      fi
    elif command -v wget >/dev/null 2>&1; then
      if ! wget -qO- "$url" | patch -p1; then
        echo "ERRO: falha ao aplicar patch de $url"
        exit 1
      fi
    else
      echo "ERRO: nem curl nem wget encontrados para baixar patches."
      exit 1
    fi
  }

  apply_patch_stream "https://www.openwall.com/lists/musl/2025/02/13/1/1"
  apply_patch_stream "https://www.openwall.com/lists/musl/2025/02/13/1/2"

  echo "==> [musl-pass1] Patches aplicados com sucesso."

  #------------------------------------
  # Configure
  #
  # Para o Pass1, vamos instalar musl em $LFS:
  #   - prefix=/usr  (dentro do sysroot)
  #   - CFLAGS simples
  #
  # O DESTDIR será "$DESTDIR$LFS" na instalação, então:
  #   - arquivo real no pacote:   mnt/lfs/usr/...
  #   - destino final (após adm): /mnt/lfs/usr/...
  #------------------------------------
  CFLAGS="$CFLAGS_MUSL" \
  ./configure \
    --prefix=/usr

  echo "==> [musl-pass1] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [musl-pass1] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [musl-pass1] make concluído"

  #------------------------------------
  # Instalação no sysroot $LFS via DESTDIR do adm
  #------------------------------------
  echo "==> [musl-pass1] Instalando em DESTDIR=${DESTDIR}${LFS}"
  mkdir -p "$DESTDIR$LFS"
  make DESTDIR="$DESTDIR$LFS" install

  echo "==> [musl-pass1] make install concluído em $DESTDIR$LFS"

  #------------------------------------
  # Garantir loader ld-musl-*.so.1 em $LFS/lib
  #
  # Depois da instalação, o loader pode estar em:
  #   - $LFS/lib/ld-musl-*.so.1
  #   - ou $LFS/usr/lib/ld-musl-*.so.1
  #
  # Vamos:
  #   1) descobrir o loader dentro de $DESTDIR$LFS
  #   2) criar symlink /mnt/lfs/lib/ld-musl-*.so.1 -> ../usr/lib/ld-musl-*.so.1
  #      se ele estiver em /usr/lib.
  #------------------------------------
  echo "==> [musl-pass1] Procurando loader ld-musl-*.so.1 dentro de $LFS"

  local LOADER LOADER_BASENAME
  LOADER=""

  if cd "$DESTDIR$LFS"; then
    LOADER="$(find . -maxdepth 4 -name 'ld-musl-*.so.1' -print | head -n1 | sed 's#^\./##' || true)"
  fi

  if [ -n "$LOADER" ]; then
    echo "==> [musl-pass1] Loader encontrado em DESTDIR+LFS: /$LOADER"
    LOADER_BASENAME="$(basename "$LOADER")"

    mkdir -p "$DESTDIR$LFS/lib"
    # Só cria symlink se ainda não existir arquivo real em $LFS/lib/<loader>
    if [ ! -e "$DESTDIR$LFS/lib/$LOADER_BASENAME" ]; then
      echo "==> [musl-pass1] Criando symlink /mnt/lfs/lib/$LOADER_BASENAME -> ../$LOADER"
      ln -sf "../$LOADER" "$DESTDIR$LFS/lib/$LOADER_BASENAME"
    fi
  else
    echo "AVISO: loader ld-musl-*.so.1 não encontrado dentro de $DESTDIR$LFS."
    echo "       Verifique a instalação do musl-pass1."
  fi

  echo "==> [musl-pass1] Build do musl-${PKG_VERSION} Pass 1 finalizado com sucesso."
}
