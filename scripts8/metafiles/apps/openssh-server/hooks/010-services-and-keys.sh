#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
# systemd
mkdir -p "${DESTDIR}/usr/lib/systemd/system"
cat > "${DESTDIR}/usr/lib/systemd/system/sshd.service" <<'UNIT'
[Unit]
Description=OpenSSH Daemon
After=network.target
[Service]
ExecStart=/usr/bin/sshd -D
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
# runit
mkdir -p "${DESTDIR}/etc/runit/sv/sshd"
cat > "${DESTDIR}/etc/runit/sv/sshd/run" <<'RUN'
#!/usr/bin/env bash
mkdir -p /etc/ssh
[ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -A
exec /usr/bin/sshd -D
RUN
chmod +x "${DESTDIR}/etc/runit/sv/sshd/run"
# sysvinit
mkdir -p "${DESTDIR}/etc/init.d"
cat > "${DESTDIR}/etc/init.d/sshd" <<'SYSV'
#!/usr/bin/env bash
case "$1" in
 start) [ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -A; /usr/bin/sshd ;;
 stop)  killall sshd || true ;;
 restart) $0 stop; $0 start ;;
 *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
SYSV
chmod +x "${DESTDIR}/etc/init.d/sshd"
echo "[openssh-server] serviços para systemd/runit/sysv instalados"
