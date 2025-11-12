#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
# systemd
mkdir -p "${DESTDIR}/usr/lib/systemd/system"
cat > "${DESTDIR}/usr/lib/systemd/system/bluetooth.service" <<'UNIT'
[Unit]
Description=Bluetooth service
After=dbus.service
[Service]
ExecStart=/usr/lib/bluetooth/bluetoothd
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
# runit
mkdir -p "${DESTDIR}/etc/runit/sv/bluetoothd"
cat > "${DESTDIR}/etc/runit/sv/bluetoothd/run" <<'RUN'
#!/usr/bin/env bash
exec /usr/lib/bluetooth/bluetoothd -n
RUN
chmod +x "${DESTDIR}/etc/runit/sv/bluetoothd/run"
# sysvinit
mkdir -p "${DESTDIR}/etc/init.d"
cat > "${DESTDIR}/etc/init.d/bluetooth" <<'SYSV'
#!/usr/bin/env bash
case "$1" in
 start) /usr/lib/bluetooth/bluetoothd -n & ;;
 stop)  killall bluetoothd || true ;;
 restart) $0 stop; $0 start ;;
 *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
SYSV
chmod +x "${DESTDIR}/etc/init.d/bluetooth"
echo "[bluez] serviços instalados"
