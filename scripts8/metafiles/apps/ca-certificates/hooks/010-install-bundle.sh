#!/usr/bin/env bash
set -Eeuo pipefail
root="${DESTDIR:-/}"
mkdir -p "$root/etc/ssl/certs"
cp -f "${SRC_CACERT_PEM:-./cacert.pem}" "$root/etc/ssl/certs/ca-certificates.crt" || true
echo "[hook ca-certificates] bundle colocado em /etc/ssl/certs/ca-certificates.crt"
