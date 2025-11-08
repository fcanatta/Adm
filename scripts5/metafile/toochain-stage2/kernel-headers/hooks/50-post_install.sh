#!/usr/bin/env sh
# Instala headers em /usr/include do sistema

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${DESTDIR:?DESTDIR não definido}"

cd "$SRC_DIR"
make mrproper
make headers
make INSTALL_HDR_PATH="${DESTDIR}/usr" headers_install
find "${DESTDIR}/usr/include" -name '.*install*' -type f -delete 2>/dev/null || true

# Metadados auxiliares
{
  echo "NAME=kernel-headers"
  echo "STAGE=2"
  echo "DESTDIR=${DESTDIR}"
  echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${DESTDIR}/usr/include/.adm-kheaders-stage2.meta" 2>/dev/null || true
