#!/usr/bin/env bash
# Script de construção do musl libc para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/libs/musl/musl.sh
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
# IMPORTANTE:
#   Este script constrói o musl como libc “de sistema” instalada em /usr.
#   Em cenários reais de cross ou bootstrap você pode querer um layout
#   mais complexo, mas aqui focamos no caso direto + aplicação dos
#   patches de segurança de 2025-02-13 (iconv).

#----------------------------------------
# Versão e origem oficial
#----------------------------------------
PKG_VERSION="1.2.5"
SRC_URL="https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"
# Se quiser verificar integridade via MD5, defina:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

pkg_build() {
  set -euo pipefail

  echo "==> [musl] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS : ${NUMJOBS:-1}"

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e flags
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
      # genérico
      CFLAGS_MUSL="-O2 -pipe"
      ;;
  esac

  echo "==> [musl] ARCH   : $ARCH"
  echo "==> [musl] CFLAGS : $CFLAGS_MUSL"

  #------------------------------------
  # Ajustes por PROFILE (informativo)
  #------------------------------------
  case "${PROFILE:-}" in
    musl)
      echo "==> [musl] PROFILE = musl (construindo a própria libc musl)"
      ;;
    glibc|"")
      echo "==> [musl] PROFILE parece ser glibc (ou vazio): construindo musl"
      echo "            a partir de um sistema baseado em glibc (caso de bootstrap)."
      ;;
    *)
      echo "==> [musl] PROFILE desconhecido (${PROFILE}), apenas informativo."
      ;;
  esac

  #------------------------------------
  # Aplicação dos patches de segurança do iconv
  #
  # Patches:
  #   1) EUC-KR: corrige checagem de bounds no lead byte, evitando
  #      load fora dos limites da tabela ksc. 2
  #   2) UTF-8 output: garante que valores inválidos de wctomb_utf8
  #      não causem overflow/underflow do ponteiro de saída. 3
  #------------------------------------
  local PATCH_BASE="https://www.openwall.com/lists/musl/2025/02/13/1"

  echo "==> [musl] Aplicando patches de segurança do iconv (EUC-KR + UTF-8 hardening)"

  apply_patch_stream() {
    local url="$1"
    echo "==> [musl] Baixando e aplicando patch: $url"
    if command -v curl >/dev/null 2>&1; then
      # -f: falha em HTTP >=400, -s: silencioso, -S: mostra erro, -L: segue redirect
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

  # Patch 1: EUC-KR decoder fix
  apply_patch_stream "${PATCH_BASE}/1"

  # Patch 2: UTF-8 output hardening
  apply_patch_stream "${PATCH_BASE}/2"

  echo "==> [musl] Patches de segurança aplicados com sucesso."

  #------------------------------------
  # Configure
  #
  #   - prefix=/usr: instalar em /usr (adm empacota via DESTDIR).
  #   - CFLAGS: simples, sem otimizações agressivas demais.
  #------------------------------------
  ./configure \
    --prefix=/usr \
    CFLAGS="$CFLAGS_MUSL"

  echo "==> [musl] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  make -j"${NUMJOBS:-1}"
  echo "==> [musl] make concluído"

  #------------------------------------
  # (Opcional) Testes
  #
  # O musl não tem um 'make check' trivial como outros projetos.
  # Se você tiver um conjunto próprio de testes, encaixe aqui.
  #------------------------------------
  # make check || true

  #------------------------------------
  # Instalação em DESTDIR
  #------------------------------------
  make DESTDIR="$DESTDIR" install
  echo "==> [musl] make install concluído em $DESTDIR"

  #------------------------------------
  # Pós-instalação em DESTDIR
  #------------------------------------
  # - garantir symlink do loader dinâmico em /lib/ld-musl-*.so.1

  # 1) Descobrir o loader ld-musl-*.so.1 dentro do DESTDIR
  local LOADER
  LOADER="$(cd "$DESTDIR" && find . -maxdepth 4 -name 'ld-musl-*.so.1' -print | head -n1 | sed 's#^\./##' || true)"

  if [ -n "$LOADER" ]; then
    echo "==> [musl] Loader dinâmico encontrado em DESTDIR: /${LOADER}"
  else
    echo "==> [musl] AVISO: loader ld-musl-*.so.1 não encontrado em DESTDIR após install."
  fi

  # 2) Criar symlink padrão em /lib (dentro do DESTDIR)
  if [ -n "$LOADER" ]; then
    local LOADER_BASENAME
    LOADER_BASENAME="$(basename "$LOADER")"

    mkdir -p "$DESTDIR/lib"
    if [ ! -e "$DESTDIR/lib/$LOADER_BASENAME" ]; then
      echo "==> [musl] Criando symlink do loader em /lib/$LOADER_BASENAME"
      ln -sf "../$LOADER" "$DESTDIR/lib/$LOADER_BASENAME"
    fi
  fi

  echo "==> [musl] Build do musl-${PKG_VERSION} finalizado com sucesso."
}
