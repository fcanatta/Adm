#!/usr/bin/env sh
# Ajustes pós-instalação (no DESTDIR), sem tocar fora do prefix/pacote

set -eu

: "${DESTDIR:?DESTDIR não definido}"
: "${PREFIX:?PREFIX não definido}"

# Garantir diretórios base
mkdir -p "${DESTDIR}${PREFIX}/bin" "${DESTDIR}${PREFIX}/lib" 2>/dev/null || true

# Opcional: remover *.la (quando indesejados). Descomente se quiser.
# find "${DESTDIR}${PREFIX}/lib" -type f -name "*.la" -exec rm -f {} + 2>/dev/null || true

# Metadados auxiliares
{
  echo "NAME=binutils"
  echo "STAGE=2"
  echo "PREFIX=${PREFIX}"
  echo "WITH_SYSTEM_ZLIB=1"
  echo "ENABLE_GOLD=${ADM_BINUTILS_ENABLE_GOLD:-0}"
  echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${DESTDIR}${PREFIX}/.adm-binutils-stage2.meta" 2>/dev/null || true
