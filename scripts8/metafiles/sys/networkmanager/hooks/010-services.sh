#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
# systemd unit
mkdir -p "${DESTDIR}/usr/lib/systemd/system"
cat > "${DESTDIR}/usr/lib/systemd/system/NetworkManager.service" <<'UNIT'
[Unit]
Description=Network Manager
After=dbus.service network-pre.target
Wants=network-pre.target
[Service]
ExecStart=/usr/sbin/NetworkManager --no-daemon
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
# runit service
mkdir -p "${DESTDIR}/etc/runit/sv/NetworkManager"
cat > "${DESTDIR}/etc/runit/sv/NetworkManager/run" <<'RUN'
#!/usr/bin/env bash
exec /usr/sbin/NetworkManager --no-daemon
RUN
chmod +x "${DESTDIR}/etc/runit/sv/NetworkManager/run"
# sysvinit
mkdir -p "${DESTDIR}/etc/init.d"
cat > "${DESTDIR}/etc/init.d/NetworkManager" <<'SYSV'
#!/usr/bin/env bash
case "$1" in
 start) /usr/sbin/NetworkManager --no-daemon & ;;
 stop)  killall NetworkManager || true ;;
 restart) $0 stop; $0 start ;;
 *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
SYSV
chmod +x "${DESTDIR}/etc/init.d/NetworkManager"
echo "[NetworkManager] serviços instalados"
