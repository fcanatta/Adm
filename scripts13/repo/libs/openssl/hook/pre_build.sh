#!/usr/bin/env bash
# pre_build: openssl 3.4.0
# - escolhe target pelo arch
# - ativa shared
# - usa /usr como prefixo

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

if [[ -f Makefile && -f configdata.pm ]]; then
    echo "[openssl/pre_build] OpenSSL já configurado, pulando."
    exit 0
fi

arch="$(uname -m)"
case "${arch}" in
    x86_64)  TARGET="linux-x86_64" ;;
    aarch64) TARGET="linux-aarch64" ;;
    i?86)    TARGET="linux-x86" ;;
    *)       TARGET="linux-generic64" ;;
esac

PROFILE="${ADM_PROFILE:-normal}"

CFLAGS_EXTRA=""
case "${PROFILE}" in
    aggressive)
        CFLAGS_EXTRA="-O3 -pipe"
        ;;
    minimal)
        CFLAGS_EXTRA="-O2 -pipe"
        ;;
    *)
        CFLAGS_EXTRA="-O2 -pipe"
        ;;
esac

export CFLAGS="${CFLAGS:-} ${CFLAGS_EXTRA}"

echo "[openssl/pre_build] Configurando OpenSSL (target=${TARGET}, profile=${PROFILE})."

./Configure \
  "${TARGET}" \
  --prefix=/usr \
  --libdir=lib \
  --openssldir=/etc/ssl \
  shared \
  enable-ec_nistp_64_gcc_128

echo "[openssl/pre_build] Configure concluído."
