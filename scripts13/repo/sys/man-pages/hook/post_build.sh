#!/usr/bin/env bash
# post_build: man-pages-6.16
# - instala as manpages em DESTDIR (ou ADM_INSTALL_ROOT)
# - simples e idempotente

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
: "${ADM_DESTDIR:="${ADM_INSTALL_ROOT:-}"}"

cd "${ADM_BUILD_DIR}"

# DEST é onde as páginas vão parar na fase de build
if [[ -n "${ADM_DESTDIR}" ]]; then
    DEST="${ADM_DESTDIR%/}"
else
    DEST="${PWD}/_dest"
fi

mkdir -p "${DEST}"

MARKER="${DEST}/.manpages-installed"
if [[ -f "${MARKER}" ]]; then
    echo "[man-pages/post_build] man-pages já instaladas em '${DEST}', pulando."
    exit 0
fi

echo "[man-pages/post_build] Instalando man-pages em '${DEST}'."

# A maioria dos pacotes man-pages usa esse padrão simples
make prefix=/usr mandir=/usr/share/man DESTDIR="${DEST}" install

touch "${MARKER}"

echo "[man-pages/post_build] Instalação concluída em '${DEST}'."
