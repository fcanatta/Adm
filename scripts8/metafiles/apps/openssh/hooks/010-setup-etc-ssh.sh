#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
mkdir -p "${DESTDIR}/etc/ssh"
if [[ ! -f "${DESTDIR}/etc/ssh/ssh_config" ]]; then
  echo "Host *" > "${DESTDIR}/etc/ssh/ssh_config"
  echo "  ServerAliveInterval 60" >> "${DESTDIR}/etc/ssh/ssh_config"
fi
echo "[openssh] /etc/ssh configurado (básico). Gere host keys no runtime."
