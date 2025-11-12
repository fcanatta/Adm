#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
# runit
mkdir -p "${DESTDIR}/etc/runit/sv/udevd"
cat > "${DESTDIR}/etc/runit/sv/udevd/run" <<'RUN'
#!/usr/bin/env bash
exec /usr/lib/udev/udevd --daemon --resolve-names=never
RUN
chmod +x "${DESTDIR}/etc/runit/sv/udevd/run"
# sysvinit
mkdir -p "${DESTDIR}/etc/init.d"
cat > "${DESTDIR}/etc/init.d/udevd" <<'SYSV'
#!/usr/bin/env bash
case "$1" in
 start) /usr/lib/udev/udevd --daemon --resolve-names=never ;;
 stop)  killall udevd || true ;;
 restart) $0 stop; $0 start ;;
 *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
SYSV
chmod +x "${DESTDIR}/etc/init.d/udevd"
echo "[eudev] serviços instalados (runit/sysv)"
