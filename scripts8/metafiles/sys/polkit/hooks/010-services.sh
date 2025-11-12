#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
# systemd
mkdir -p "${DESTDIR}/usr/lib/systemd/system"
cat > "${DESTDIR}/usr/lib/systemd/system/polkit.service" <<'UNIT'
[Unit]
Description=Authorization Manager
After=dbus.service
[Service]
ExecStart=/usr/lib/polkit-1/polkitd --no-debug
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
# runit
mkdir -p "${DESTDIR}/etc/runit/sv/polkitd"
cat > "${DESTDIR}/etc/runit/sv/polkitd/run" <<'RUN'
#!/usr/bin/env bash
exec /usr/lib/polkit-1/polkitd --no-debug
RUN
chmod +x "${DESTDIR}/etc/runit/sv/polkitd/run"
# sysvinit
mkdir -p "${DESTDIR}/etc/init.d"
cat > "${DESTDIR}/etc/init.d/polkitd" <<'SYSV'
#!/usr/bin/env bash
case "$1" in
 start) /usr/lib/polkit-1/polkitd --no-debug & ;;
 stop)  killall polkitd || true ;;
 restart) $0 stop; $0 start ;;
 *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
SYSV
chmod +x "${DESTDIR}/etc/init.d/polkitd"
echo "[polkit] serviços instalados"
