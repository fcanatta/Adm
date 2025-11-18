#!/usr/bin/env bash
# pre_build: util-linux 2.41.2
# - ativa só o essencial
# - build out-of-tree
# - integra ncurses+readline se presentes

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

BUILD_DIR="${ADM_BUILD_DIR}/build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ -f config.status ]]; then
    echo "[util-linux/pre_build] Já configurado em '${BUILD_DIR}', pulando."
    exit 0
fi

PROFILE="${ADM_PROFILE:-normal}"

export CPPFLAGS="${CPPFLAGS:-} -I/usr/include"
export LDFLAGS="${LDFLAGS:-} -L/usr/lib"

echo "[util-linux/pre_build] Configurando util-linux (profile=${PROFILE})."

../configure \
  --prefix=/usr \
  --bindir=/usr/bin \
  --sbindir=/usr/sbin \
  --libdir=/usr/lib \
  --disable-static \
  --enable-shared \
  --without-python \
  --without-systemd \
  --with-ncurses \
  --enable-libuuid \
  --enable-libblkid \
  --enable-fsck

echo "[util-linux/pre_build] configure concluído."
