#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
# runit
mkdir -p "${DESTDIR}/etc/runit/sv/mdevd"
cat > "${DESTDIR}/etc/runit/sv/mdevd/run" <<'RUN'
#!/usr/bin/env bash
echo /sbin/mdev > /proc/sys/kernel/hotplug || true
exec /sbin/mdev -s
RUN
chmod +x "${DESTDIR}/etc/runit/sv/mdevd/run"
# sysvinit script mínimo
mkdir -p "${DESTDIR}/etc/init.d"
cat > "${DESTDIR}/etc/init.d/mdev" <<'SYSV'
#!/usr/bin/env bash
case "$1" in
 start) echo /sbin/mdev > /proc/sys/kernel/hotplug; /sbin/mdev -s ;;
 stop)  echo > /proc/sys/kernel/hotplug || true ;;
 restart) $0 stop; $0 start ;;
 *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
SYSV
chmod +x "${DESTDIR}/etc/init.d/mdev"
echo "[mdev] serviços instalados (runit/sysv)"
