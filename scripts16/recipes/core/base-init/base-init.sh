PKG_NAME="base-init"
PKG_VERSION="1.0"
PKG_RELEASE="1"
PKG_GROUPS="core init"
PKG_DESC="Init simples baseado em BusyBox para rootfs"
PKG_DEPENDS="busybox"

pkg_prepare() { :; }
pkg_build() { :; }

pkg_install() {
  # links e scripts
  install -d "$PKG_DESTDIR/sbin" "$PKG_DESTDIR/etc/rc.d"

  ln -sf /bin/busybox "$PKG_DESTDIR/sbin/init"

  install -m644 /dev/stdin "$PKG_DESTDIR/etc/inittab" << "EOF"
# Begin /etc/inittab - BusyBox init

# Script de inicialização de sistema (roda uma vez, no boot)
::sysinit:/etc/rc.d/rcS

# Shell “askfirst” no console primário, útil pra debug
::askfirst:-/bin/sh

# Getty em tty1 (terminal de login padrão)
tty1::respawn:/sbin/getty 38400 tty1

# Atalhos de controle
::ctrlaltdel:/sbin/reboot
::shutdown:/etc/rc.d/rcK

# End /etc/inittab
EOF

  install -m755 /dev/stdin "$PKG_DESTDIR/etc/rc.d/rcS" << "EOF"
#!/bin/sh
# Begin /etc/rc.d/rcS - Script de boot

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

echo ">>> rcS: iniciando sistema..."

# Monta pseudo sistemas de arquivos básicos
mount -t proc proc /proc
mount -t sysfs sysfs /sys

# Se usar devtmpfs (recomendado)
if grep -qw devtmpfs /proc/filesystems; then
    mount -t devtmpfs devtmpfs /dev
fi

# mdev (gerenciador simples de /dev do BusyBox)
echo /sbin/mdev > /proc/sys/kernel/hotplug
mdev -s

# Monta /run (tmpfs) se você quiser usar PID files, etc.
[ -d /run ] || mkdir -p /run
mountpoint -q /run || mount -t tmpfs tmpfs /run

# Ajusta hostname básico
[ -f /etc/hostname ] && {
    HOSTNAME="$(cat /etc/hostname)"
    echo ">>> hostname: $HOSTNAME"
    hostname "$HOSTNAME"
}

# Ativa swap se tiver
[ -f /etc/fstab ] && swapon -a 2>/dev/null

# Monta o restante das entradas de /etc/fstab (exceto pseudo-fs)
if [ -f /etc/fstab ]; then
    # monta tudo exceto proc, sysfs, devtmpfs, tmpfs
    mount -a -t nocifs,nonfs,nodevpts,nonfs4 2>/dev/null
fi

echo ">>> rcS: boot básico concluído."
exit 0

# End /etc/rc.d/rcS
EOF

  install -m755 /dev/stdin "$PKG_DESTDIR/etc/rc.d/rcK" << "EOF"
#!/bin/sh
# Begin /etc/rc.d/rcK - Script de shutdown

echo ">>> rcK: iniciando desligamento..."

# Sincroniza e tenta desmontar sistemas de arquivos
sync

# Tenta desmontar tudo, exceto root
# Ordem aproximada – pode ajustar conforme seu layout
for m in run dev/pts dev/shm dev proc sys; do
    if mountpoint -q "/$m"; then
        umount "/$m" 2>/dev/null || echo "Aviso: não consegui desmontar /$m"
    fi
done

sync
echo ">>> rcK: desligamento básico concluído."

exit 0

# End /etc/rc.d/rcK
EOF
}
