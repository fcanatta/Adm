#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
mkdir -p "${DESTDIR}/etc"
if [[ ! -f "${DESTDIR}/etc/inittab" ]]; then
cat > "${DESTDIR}/etc/inittab" <<'TAB'
id:3:initdefault:
si::sysinit:/etc/init.d/rcS
l3:3:wait:/etc/init.d/rc 3
ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now
TAB
fi
echo "[sysvinit] inittab mínimo criado"
