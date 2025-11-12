#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
mkdir -p "${DESTDIR}/etc/systemd/system/default.target.wants"
echo "[systemd] unidades base ok (use systemctl enable ... no runtime)"
