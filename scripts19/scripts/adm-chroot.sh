#!/usr/bin/env bash
# Gerenciador completo do chroot LFS para uso com o adm
#
# Funcionalidades:
#   - setup   : prepara o chroot em $LFS (ownership, mounts, resolv.conf,
#               /mnt/adm bind, criação de dirs e arquivos básicos)
#   - enter   : garante setup, entra no chroot e, ao sair, faz cleanup
#   - cleanup : desmonta com segurança tudo que foi montado em $LFS
#   - status  : mostra estado atual dos mounts relacionados ao $LFS
#
# Padrão (sem argumentos): "enter".
#
# Variáveis:
#   LFS      : raiz do sistema LFS (padrão /mnt/lfs)
#   ADM_ROOT : onde estão os scripts do adm no host (padrão /mnt/adm)
#   ADM_BIN  : caminho do binário do adm (por padrão autodetectado via PATH)
#
# Requisitos:
#   - rodar como root
#   - capítulos anteriores do LFS já feitos (toolchain em $LFS/tools, etc.)

set -euo pipefail

LFS="${LFS:-/mnt/lfs}"
ADM_ROOT="${ADM_ROOT:-/mnt/adm}"
ADM_BIN="${ADM_BIN:-$(command -v adm 2>/dev/null || true)}"

# ---------- helpers ----------

die() {
  echo "ERRO: $*" >&2
  exit 1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Este script precisa ser executado como root."
  fi
}

check_lfs_dir() {
  if [ ! -d "$LFS" ]; then
    die "Diretório LFS ($LFS) não existe. Crie e monte a partição do LFS em $LFS."
  fi
}

run() {
  echo "+ $*"
  "$@"
}

is_mounted() {
  mountpoint -q "$1"
}

# ---------- STATUS ----------

show_status() {
  echo "==> Status de mounts relacionados a $LFS:"
  grep " $LFS" /proc/mounts || echo "(nenhum mount relativo a $LFS encontrado)"
}

# ---------- SETUP (host) ----------

setup_ownership() {
  echo "==> Ajustando ownership de diretórios em $LFS para root:root (cap. 7.2)"

  for d in usr lib var etc bin sbin tools; do
    if [ -e "$LFS/$d" ]; then
      run chown -R root:root "$LFS/$d"
    fi
  done
  if [ -e "$LFS/lib64" ]; then
    run chown -R root:root "$LFS/lib64"
  fi
}

setup_kernfs() {
  echo "==> Montando sistemas de arquivos kernel em $LFS (cap. 7.3)"

  run mkdir -pv "$LFS"/{dev,proc,sys,run}

  # /dev
  if ! is_mounted "$LFS/dev"; then
    run mount -v --bind /dev "$LFS/dev"
  else
    echo "   $LFS/dev já montado (bind)."
  fi

  # devpts
  if ! is_mounted "$LFS/dev/pts"; then
    run mkdir -pv "$LFS/dev/pts"
    run mount -vt devpts devpts "$LFS/dev/pts" -o gid=5,mode=620
  else
    echo "   $LFS/dev/pts já montado."
  fi

  # proc
  if ! is_mounted "$LFS/proc"; then
    run mount -vt proc proc "$LFS/proc"
  else
    echo "   $LFS/proc já montado."
  fi

  # sysfs
  if ! is_mounted "$LFS/sys"; then
    run mount -vt sysfs sysfs "$LFS/sys"
  else
    echo "   $LFS/sys já montado."
  fi

  # run (tmpfs)
  if ! is_mounted "$LFS/run"; then
    run mount -vt tmpfs tmpfs "$LFS/run"
  else
    echo "   $LFS/run já montado."
  fi

  # /dev/shm
  if [ -h "$LFS/dev/shm" ]; then
    run mkdir -pv "$LFS/$(readlink "$LFS/dev/shm")"
  else
    run mkdir -pv "$LFS/dev/shm"
  fi
}

setup_resolv() {
  echo "==> Copiando /etc/resolv.conf para o chroot"
  run mkdir -pv "$LFS/etc"

  if [ -f /etc/resolv.conf ]; then
    run cp -vL /etc/resolv.conf "$LFS/etc/resolv.conf"
  else
    echo "AVISO: /etc/resolv.conf não existe no host; DNS pode falhar dentro do chroot."
  fi
}

setup_adm_mount_and_bin() {
  echo "==> Preparando adm dentro do chroot"

  # Bind-mount dos scripts do adm: /mnt/adm (host) -> $LFS/mnt/adm
  if [ -d "$ADM_ROOT" ]; then
    run mkdir -pv "$LFS/mnt"
    run mkdir -pv "$LFS/mnt/adm"
    if ! is_mounted "$LFS/mnt/adm"; then
      run mount --bind "$ADM_ROOT" "$LFS/mnt/adm"
    else
      echo "   $LFS/mnt/adm já está montado (bind)."
    fi
  else
    echo "AVISO: Diretório ADM_ROOT=$ADM_ROOT não existe; scripts de build não estarão no chroot."
  fi

  # Copiar binário do adm
  if [ -n "$ADM_BIN" ] && [ -x "$ADM_BIN" ]; then
    run mkdir -pv "$LFS/usr/local/bin"
    run cp -v "$ADM_BIN" "$LFS/usr/local/bin/adm"
    run chmod 0755 "$LFS/usr/local/bin/adm"
  else
    echo "AVISO: Binário 'adm' não encontrado (ADM_BIN=$ADM_BIN); só scripts estarão disponíveis."
  fi
}

bootstrap_in_chroot() {
  echo "==> Entrando no chroot (script interno) para criar diretórios e arquivos básicos (cap. 7.5 e 7.6)"

  chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/bin:/usr/sbin:/bin:/sbin \
    /bin/bash -xe << 'EOF_CHROOT'

# ===== Dentro do chroot a partir daqui =====

echo "=== [chroot] Criando diretórios do FHS (cap. 7.5) ==="

mkdir -pv /{boot,home,mnt,opt,srv}
mkdir -pv /etc/{opt,sysconfig}
mkdir -pv /lib/firmware
mkdir -pv /media/{floppy,cdrom}
mkdir -pv /usr/{,local/}{bin,lib,sbin,include,src}
mkdir -pv /usr/{,local/}share/{color,dict,doc,info,locale,man}
mkdir -pv /usr/{,local/}share/{misc,terminfo,zoneinfo}
mkdir -pv /usr/{,local/}share/man/man{1..8}
mkdir -pv /var/{cache,local,log,mail,opt,spool}
mkdir -pv /var/lib/{color,misc,locate}

ln -sfv /run /var/run
ln -sfv /run/lock /var/lock

install -dv -m 0750 /root
install -dv -m 1777 /tmp /var/tmp

echo "=== [chroot] /etc/mtab -> /proc/self/mounts ==="
ln -svf /proc/self/mounts /etc/mtab

echo "=== [chroot] /etc/hosts ==="
if [ ! -f /etc/hosts ]; then
cat > /etc/hosts << "EOF_HOSTS"
127.0.0.1  localhost lfs
::1        localhost
EOF_HOSTS
fi

echo "=== [chroot] /etc/passwd ==="
if [ ! -f /etc/passwd ]; then
cat > /etc/passwd << "EOF_PASSWD"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF_PASSWD
fi

echo "=== [chroot] /etc/group ==="
if [ ! -f /etc/group ]; then
cat > /etc/group << "EOF_GROUP"
root:x:0:
bin:x:1:
daemon:x:6:
sys:x:3:
kmem:x:9:
tty:x:5:
disk:x:8:
lp:x:7:
mail:x:12:
uucp:x:14:
man:x:15:
log:x:16:
adm:x:17:
wheel:x:10:
cdrom:x:19:
audio:x:63:
video:x:39:
input:x:24:
kvm:x:61:
render:x:122:
tape:x:33:
sudo:x:27:
floppy:x:11:
users:x:100:
nogroup:x:65534:
utmp:x:22:
EOF_GROUP
fi

echo "=== [chroot] Logs em /var/log ==="
touch /var/log/{btmp,faillog,lastlog,wtmp}
chgrp -v utmp /var/log/lastlog /var/log/wtmp || true
chmod -v 664 /var/log/{lastlog,wtmp} || true
chmod -v 600 /var/log/btmp || true
chmod -v 600 /var/log/faillog || true

echo "=== [chroot] Conteúdo de /var/log ==="
ls -l /var/log

echo "=== [chroot] Bootstrap básico do capítulo 7 concluído. ==="
EOF_CHROOT
}

do_setup() {
  need_root
  check_lfs_dir
  setup_ownership
  setup_kernfs
  setup_resolv
  setup_adm_mount_and_bin
  bootstrap_in_chroot
  echo "==> Setup do chroot LFS em $LFS concluído."
}

# ---------- CLEANUP (host) ----------

do_cleanup() {
  need_root
  check_lfs_dir

  echo "==> Desmontando mounts do chroot em ordem segura"

  # Ordem inversa da montagem:
  # 1) bind /mnt/adm
  if is_mounted "$LFS/mnt/adm"; then
    run umount -v "$LFS/mnt/adm"
  fi

  # 2) devpts
  if is_mounted "$LFS/dev/pts"; then
    run umount -v "$LFS/dev/pts"
  fi

  # 3) shm (se for mount separado; geralmente não é)
  if is_mounted "$LFS/dev/shm"; then
    run umount -v "$LFS/dev/shm"
  fi

  # 4) run, proc, sys, dev (nessa ordem)
  if is_mounted "$LFS/run"; then
    run umount -v "$LFS/run"
  fi
  if is_mounted "$LFS/proc"; then
    run umount -v "$LFS/proc"
  fi
  if is_mounted "$LFS/sys"; then
    run umount -v "$LFS/sys"
  fi
  if is_mounted "$LFS/dev"; then
    run umount -v "$LFS/dev"
  fi

  echo "==> Cleanup concluído. Montagens atuais:"
  show_status
}

# ---------- ENTER (host) ----------

do_enter() {
  need_root
  check_lfs_dir

  # Faz setup mínimo se ainda não estiver montado
  if ! is_mounted "$LFS/dev" || ! is_mounted "$LFS/proc" || ! is_mounted "$LFS/sys"; then
    echo "==> Ambiente de chroot ainda não montado; rodando setup primeiro."
    do_setup
  else
    # Garante bind do adm e resolv.conf atualizados
    setup_adm_mount_and_bin
  fi

  echo "==> Entrando no chroot. Ao sair do bash, farei cleanup automático."

  chroot "$LFS" /usr/bin/env -i \
    HOME=/root \
    TERM="${TERM:-xterm}" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin:/bin:/sbin:/tools/bin \
    /bin/bash --login

  echo "==> Você saiu do chroot. Iniciando cleanup..."
  do_cleanup
}

# ---------- MAIN ----------

CMD="${1:-enter}"

case "$CMD" in
  setup)
    do_setup
    ;;
  enter)
    do_enter
    ;;
  cleanup)
    do_cleanup
    ;;
  status)
    show_status
    ;;
  *)
    echo "Uso: $0 [setup|enter|cleanup|status]"
    exit 1
    ;;
esac
