#!/usr/bin/env sh
# Instala Linux API headers em $DESTDIR/usr/include

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${DESTDIR:?DESTDIR não definido}"

cd "$SRC_DIR"

# Limpeza do tree para garantir integridade
make mrproper

# Gera headers (include/uapi e afins) e instala no DESTDIR
# headers_install usa INSTALL_HDR_PATH para apontar para $DESTDIR/usr
make headers
make INSTALL_HDR_PATH="${DESTDIR}/usr" headers_install

# Os headers gerados não devem conter artefatos temporários .install
# (normalmente o target já limpa; reforçamos)
find "${DESTDIR}/usr/include" -name '.*install*' -type f -delete 2>/dev/null || true

# Metadados auxiliares
{
  echo "NAME=kernel-headers"
  echo "STAGE=0"
  echo "DESTDIR=${DESTDIR}"
  echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${DESTDIR}/usr/include/.adm-kheaders-stage0.meta" 2>/dev/null || true
