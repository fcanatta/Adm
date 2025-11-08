#!/usr/bin/env sh
# Instala apenas os headers da musl em $DESTDIR/usr/include

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${DESTDIR:?DESTDIR não definido}"

# A própria musl fornece alvo 'install-headers'
make -C "$SRC_DIR" DESTDIR="$DESTDIR" install-headers

# Garantir diretórios de libs básicos para próximos estágios, sem criar libc real
mkdir -p "$DESTDIR/lib" "$DESTDIR/usr/lib" 2>/dev/null || true

# Metadado auxiliar para diagnóstico
{
  echo "NAME=musl-headers"
  echo "STAGE=0"
  echo "DESTDIR=${DESTDIR}"
  echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$DESTDIR/usr/include/.adm-musl-stage0.meta" 2>/dev/null || true
