#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
# systemd
mkdir -p "${DESTDIR}/usr/lib/systemd/system"
cat > "${DESTDIR}/usr/lib/systemd/system/wpa_supplicant.service" <<'UNIT'
[Unit]
Description=WPA supplicant
After=network-pre.target
[Service]
ExecStart=/usr/sbin/wpa_supplicant -u -s -c /etc/wpa_supplicant/wpa_supplicant.conf -i wlan0
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
# runit
mkdir -p "${DESTDIR}/etc/runit/sv/wpa_supplicant"
cat > "${DESTDIR}/etc/runit/sv/wpa_supplicant/run" <<'RUN'
#!/usr/bin/env bash
exec /usr/sbin/wpa_supplicant -u -s -c /etc/wpa_supplicant/wpa_supplicant.conf -i wlan0
RUN
chmod +x "${DESTDIR}/etc/runit/sv/wpa_supplicant/run"
# sysvinit
mkdir -p "${DESTDIR}/etc/init.d"
cat > "${DESTDIR}/etc/init.d/wpa_supplicant" <<'SYSV'
#!/usr/bin/env bash
case "$1" in
 start) /usr/sbin/wpa_supplicant -u -s -c /etc/wpa_supplicant/wpa_supplicant.conf -i wlan0 & ;;
 stop)  killall wpa_supplicant || true ;;
 restart) $0 stop; $0 start ;;
 *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
SYSV
chmod +x "${DESTDIR}/etc/init.d/wpa_supplicant"
echo "[wpa_supplicant] serviços instalados (crie /etc/wpa_supplicant/wpa_supplicant.conf)"
