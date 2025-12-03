#!/usr/bin/env bash
# Script de construção do Iana-Etc para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/base/iana-etc/iana-etc.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball
#   DESTDIR  : raiz de instalação temporária (pkgroot)
#   PROFILE  : glibc / musl / outro (string) -> aqui é só informativo
#   NUMJOBS  : número de jobs para o make   -> não usamos aqui
#
# Este script deve definir:
#   PKG_VERSION
#   SRC_URL
#   função pkg_build()
#
# Fonte usada: projeto Mic92/iana-etc, release 20251120. 
#   - Gera arquivos /etc/protocols e /etc/services a partir dos dados da IANA.
#   - README do projeto: "python3 update.py out" gera esses arquivos. 

#----------------------------------------
# Versão e origem
#----------------------------------------
PKG_VERSION="20251120"

# Tarball de release do GitHub (auto-gerado a partir da tag):
# O arquivo terá nome iana-etc-${PKG_VERSION}.tar.gz com diretório raiz iana-etc-${PKG_VERSION}
SRC_URL="https://github.com/Mic92/iana-etc/archive/refs/tags/${PKG_VERSION}.tar.gz"

pkg_build() {
  set -euo pipefail

  echo "==> [iana-etc] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"

  cd "$SRC_DIR"

  #------------------------------------
  # PROFILE é só informativo
  #------------------------------------
  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [iana-etc] PROFILE = glibc (ou vazio) – dados servem pra qualquer libc."
      ;;
    musl)
      echo "==> [iana-etc] PROFILE = musl – dados de rede idem."
      ;;
    *)
      echo "==> [iana-etc] PROFILE desconhecido (${PROFILE}), apenas log."
      ;;
  esac

  #------------------------------------
  # Instalação: queremos apenas /etc/protocols e /etc/services
  #
  # Cenário 1 (ideal/compatível com tarball estilo LFS):
  #   - Já existem arquivos 'services' e 'protocols' no topo do source:
  #     cp services protocols /etc
  #
  # Cenário 2 (tarball puro do GitHub):
  #   - Só tem scripts; usamos 'python3 update.py out' como no README
  #     e copiamos out/services e out/protocols.
  #------------------------------------

  mkdir -p "$DESTDIR/etc"

  if [ -f "services" ] && [ -f "protocols" ]; then
    # Estilo LFS antigo: iana-etc-*.tar.* com arquivos prontos
    echo "==> [iana-etc] Encontrados arquivos 'services' e 'protocols' no source."
    echo "==> [iana-etc] Copiando para $DESTDIR/etc"
    install -m 0644 services   "$DESTDIR/etc/services"
    install -m 0644 protocols  "$DESTDIR/etc/protocols"
  else
    echo "==> [iana-etc] Arquivos 'services' e 'protocols' não encontrados no topo do source."
    echo "==> [iana-etc] Tentando gerar usando update.py (formato Mic92/iana-etc)."

    if [ ! -f "update.py" ]; then
      echo "ERRO: update.py não encontrado no source e não há 'services'/'protocols' prontos."
      echo "      Verifique se o tarball corresponde ao projeto Mic92/iana-etc ou a um tarball LFS."
      exit 1
    fi

    # Verifica python3
    local PYTHON_BIN="${PYTHON3:-python3}"
    if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
      echo "ERRO: python3 não encontrado no PATH (nem PYTHON3=custom)."
      echo "      É necessário para rodar update.py e gerar services/protocols."
      exit 1
    fi

    echo "==> [iana-etc] Usando $PYTHON_BIN para rodar update.py"
    local OUTDIR
    OUTDIR="$(pwd)/out"

    rm -rf "$OUTDIR"
    mkdir -p "$OUTDIR"

    # Conforme README do projeto: "python3 update.py out" 
    "$PYTHON_BIN" update.py "$OUTDIR"

    if [ ! -f "$OUTDIR/services" ] || [ ! -f "$OUTDIR/protocols" ]; then
      echo "ERRO: update.py foi executado, mas $OUTDIR/services ou $OUTDIR/protocols não existem."
      exit 1
    fi

    echo "==> [iana-etc] Copiando services e protocols gerados para $DESTDIR/etc"
    install -m 0644 "$OUTDIR/services"   "$DESTDIR/etc/services"
    install -m 0644 "$OUTDIR/protocols"  "$DESTDIR/etc/protocols"
  fi

  echo "==> [iana-etc] Instalação concluída em $DESTDIR/etc"
  echo "==> [iana-etc] Build do Iana-Etc-${PKG_VERSION} finalizado com sucesso."
}
