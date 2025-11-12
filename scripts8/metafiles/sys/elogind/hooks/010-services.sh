#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
# runit
mkdir -p "${DESTDIR}/etc/runit/sv/elogind"
cat > "${DESTDIR}/etc/runit/sv/elogind/run" <<'RUN'
#!/usr/bin/env bash
exec /usr/lib/elogind/elogind --no-pam
RUN
chmod +x "${DESTDIR}/etc/runit/sv/elogind/run"
# sysvinit
mkdir -p "${DESTDIR}/etc/init.d"
cat > "${DESTDIR}/etc/init.d/elogind" <<'SYSV'
#!/usr/bin/env bash
case "$1" in
 start) /usr/lib/elogind/elogind --no-pam & ;;
 stop)  killall elogind || true ;;
 restart) $0 stop; $0 start ;;
 *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
SYSV
chmod +x "${DESTDIR}/etc/init.d/elogind"
echo "[elogind] serviços para runit/sysv prontos"
