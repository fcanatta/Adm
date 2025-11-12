#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
# systemd
mkdir -p "${DESTDIR}/usr/lib/systemd/system"
cat > "${DESTDIR}/usr/lib/systemd/system/avahi-daemon.service" <<'UNIT'
[Unit]
Description=Avahi mDNS/DNS-SD Stack
After=dbus.service
[Service]
ExecStart=/usr/sbin/avahi-daemon -s
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
# runit
mkdir -p "${DESTDIR}/etc/runit/sv/avahi-daemon"
cat > "${DESTDIR}/etc/runit/sv/avahi-daemon/run" <<'RUN'
#!/usr/bin/env bash
exec /usr/sbin/avahi-daemon -s
RUN
chmod +x "${DESTDIR}/etc/runit/sv/avahi-daemon/run"
# sysvinit
mkdir -p "${DESTDIR}/etc/init.d"
cat > "${DESTDIR}/etc/init.d/avahi-daemon" <<'SYSV'
#!/usr/bin/env bash
case "$1" in
 start) /usr/sbin/avahi-daemon -s & ;;
 stop)  killall avahi-daemon || true ;;
 restart) $0 stop; $0 start ;;
 *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
SYSV
chmod +x "${DESTDIR}/etc/init.d/avahi-daemon"
echo "[avahi] serviços instalados"
