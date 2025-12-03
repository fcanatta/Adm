#!/usr/bin/env bash
# Script de construção do tzdata para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/base/tzdata/tzdata.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball
#   DESTDIR  : raiz de instalação temporária (pkgroot)
#   PROFILE  : glibc / musl / outro (string)  -> não é usado aqui
#   NUMJOBS  : número de jobs para o make     -> não é usado aqui
#
# Este script deve definir:
#   PKG_VERSION
#   SRC_URL
#   função pkg_build()
#
# NOTA:
#   - tzdata é basicamente um conjunto de arquivos de dados compilados
#     pelo binário 'zic' (parte do próprio glibc ou do pacote de zoneinfo).
#   - assumo que você tem 'zic' disponível no sistema host (/usr/sbin/zic).
#   - o script segue a lógica do LFS para geração de zonas.

#----------------------------------------
# Versão / origem
#----------------------------------------
PKG_VERSION="2025a"
# Ajuste o nome do tarball conforme a versão real:
#   Exemplo típico: tzdata2025a.tar.gz ou tzdata2025a.tar.lz;
#   aqui vou usar .tar.gz como base genérica.
SRC_URL="https://data.iana.org/time-zones/releases/tzdata${PKG_VERSION}.tar.gz"

pkg_build() {
  set -euo pipefail

  echo "==> [tzdata] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"

  cd "$SRC_DIR"

  #------------------------------------
  # Verificar 'zic'
  #------------------------------------
  local ZIC_BIN="${ZIC:-zic}"

  if ! command -v "$ZIC_BIN" >/dev/null 2>&1; then
    echo "ERRO: não encontrei 'zic' no PATH (nem ZIC=custom)."
    echo "      Instale glibc com zic, ou adicione zic ao PATH, antes de construir tzdata."
    exit 1
  fi

  echo "==> [tzdata] Usando zic: $(command -v "$ZIC_BIN")"

  #------------------------------------
  # Diretórios de instalação dentro do DESTDIR
  #------------------------------------
  local ZONEINFO_DIR="$DESTDIR/usr/share/zoneinfo"
  local ZONEINFO_POSIX_DIR="$ZONEINFO_DIR/posix"
  local ZONEINFO_RIGHT_DIR="$ZONEINFO_DIR/right"

  mkdir -p "$ZONEINFO_DIR" "$ZONEINFO_POSIX_DIR" "$ZONEINFO_RIGHT_DIR"

  #------------------------------------
  # Arquivos de zoneinfo / zonas
  #
  # LFS usa:
  #   zic -L /dev/null   -d /usr/share/zoneinfo       \
  #       -y "sh yearistype.sh" africa antarctica ...
  #
  # Aqui usamos o mesmo estilo, mas apontando para DESTDIR.
  #------------------------------------
  echo "==> [tzdata] Gerando arquivos de zona em $ZONEINFO_DIR"

  # Lista de arquivos de zona principais (padrão LFS)
  local ZONEFILES="africa antarctica asia australasia europe northamerica southamerica etcetera backward"

  # Zona principal (sem leap seconds)
  "$ZIC_BIN" -L /dev/null -d "$ZONEINFO_DIR" \
             -y "sh yearistype.sh" $ZONEFILES

  # Versão POSIX (sem segundos bissextos; compatível com POSIX)
  "$ZIC_BIN" -L /dev/null -d "$ZONEINFO_POSIX_DIR" \
             -y "sh yearistype.sh" $ZONEFILES

  # Versão RIGHT (com segundos bissextos, se o arquivo 'leapseconds' existir)
  if [ -f "leapseconds" ]; then
    "$ZIC_BIN" -L leapseconds -d "$ZONEINFO_RIGHT_DIR" \
               -y "sh yearistype.sh" $ZONEFILES
  else
    echo "AVISO: arquivo 'leapseconds' não encontrado; pulando geração RIGHT."
  fi

  #------------------------------------
  # Zona UTC (arquivo 'posixrules' e link /usr/share/zoneinfo/UTC)
  #------------------------------------
  echo "==> [tzdata] Criando zona UTC e posixrules"

  # Gera zona UTC simples
  "$ZIC_BIN" -d "$ZONEINFO_DIR" -p America/New_York || true

  # Garante link para /usr/share/zoneinfo/UTC
  if [ ! -f "$ZONEINFO_DIR/UTC" ] && [ -f "$ZONEINFO_DIR/Etc/UTC" ]; then
    ln -sf "Etc/UTC" "$ZONEINFO_DIR/UTC"
  fi

  echo "==> [tzdata] Build do tzdata-${PKG_VERSION} finalizado (dados em $ZONEINFO_DIR)."
}
