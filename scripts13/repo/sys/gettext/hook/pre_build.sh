#!/usr/bin/env bash
# pre_build: gettext 0.26
# - desativa linguagens extras que você provavelmente não usa (java, csharp, etc.)
# - build out-of-tree

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[gettext/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

PROFILE="${ADM_PROFILE:-normal}"

export CPPFLAGS="${CPPFLAGS:-} -I/usr/include"
export LDFLAGS="${LDFLAGS:-} -L/usr/lib"

echo "[gettext/pre_build] Configurando gettext (profile=${PROFILE})."

../configure \
  --prefix=/usr \
  --disable-static \
  --enable-shared \
  --disable-java \
  --disable-csharp \
  --without-emacs \
  --with-included-gettext

echo "[gettext/pre_build] configure concluído."
