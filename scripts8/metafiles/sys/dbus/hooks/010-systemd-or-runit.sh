#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
# Unit systemd
mkdir -p "${DESTDIR}/usr/lib/systemd/system"
cat > "${DESTDIR}/usr/lib/systemd/system/dbus.service" <<'UNIT'
[Unit]
Description=D-Bus System Message Bus
[Service]
ExecStart=/usr/bin/dbus-daemon --system --address=systemd: --nofork --nopidfile --systemd-activation
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
# runit service (supervise)
mkdir -p "${DESTDIR}/etc/runit/sv/dbus"
cat > "${DESTDIR}/etc/runit/sv/dbus/run" <<'RUN'
#!/usr/bin/env bash
exec /usr/bin/dbus-daemon --system --nofork --nopidfile
RUN
chmod +x "${DESTDIR}/etc/runit/sv/dbus/run"
echo "[dbus] units para systemd/runit instalados"
