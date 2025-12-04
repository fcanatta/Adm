#!/usr/bin/env bash
# adm-chroot.sh
#
# Gerenciador de chroot para uso com o adm (seu gerenciador de pacotes).
#
# Funcionalidades:
#   - setup   : prepara o chroot em $ADM_ROOTFS
#               (ownership básico, mounts /dev /proc /sys /run,
#                bind de /mnt/adm, criação de diretórios FHS e arquivos básicos)
#   - enter   : garante setup, entra no chroot e, ao sair, faz cleanup
#   - cleanup : desmonta com segurança tudo que foi montado em $ADM_ROOTFS
#   - status  : mostra estado atual dos mounts relacionados ao $ADM_ROOTFS
#
# Padrão (sem argumentos): "enter".
#
# Variáveis de ambiente:
#   ADM_ROOTFS : raiz do sistema alvo (ex.: /opt/systems/glibc-root)
#                (padrão seguro: /mnt/adm-root, para nunca pegar "/" por acidente)
#   ADM_ROOT   : onde estão os scripts do adm no host (padrão /mnt/adm)
#   ADM_BIN    : caminho do binário do adm (por padrão autodetectado via PATH)
#   CHROOT_NAME: nome para aparecer no PS1 dentro do chroot (padrão: basename de ADM_ROOTFS)
#
# Requisitos:
#   - rodar como root
#   - o root do sistema alvo já deve existir (ADM_ROOTFS)

set -euo pipefail

# ---------- Configuração básica ----------

ADM_ROOTFS="${ADM_ROOTFS:-/mnt/adm-root}"
ADM_ROOT="${ADM_ROOT:-/mnt/adm}"
ADM_BIN="${ADM_BIN:-$(command -v adm 2>/dev/null || true)}"

# Normaliza ADM_ROOTFS (remove barra final, exceto "/")
case "$ADM_ROOTFS" in
  /) ;;  # nunca mexer
  */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
esac

CHROOT_NAME="${CHROOT_NAME:-$(basename "$ADM_ROOTFS")}"

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

check_rootfs_dir() {
  if [ ! -d "$ADM_ROOTFS" ]; then
    die "Diretório raiz do sistema alvo (ADM_ROOTFS=$ADM_ROOTFS) não existe. Crie/montar a partição antes."
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
  echo "==> Status de mounts relacionados a $ADM_ROOTFS:"
  grep " $ADM_ROOTFS" /proc/mounts || echo "(nenhum mount relativo a $ADM_ROOTFS encontrado)"
}

# ---------- SETUP (host) ----------

setup_ownership() {
  echo "==> Ajustando ownership básico de diretórios em $ADM_ROOTFS para root:root"

  # Conjunto mínimo de diretórios do sistema raiz
  for d in usr lib var etc bin sbin lib64; do
    if [ -e "$ADM_ROOTFS/$d" ]; then
      run chown -R root:root "$ADM_ROOTFS/$d"
    fi
  done
}

setup_kernfs() {
  echo "==> Montando sistemas de arquivos kernel em $ADM_ROOTFS"

  run mkdir -pv "$ADM_ROOTFS"/{dev,proc,sys,run}

  # /dev
  if ! is_mounted "$ADM_ROOTFS/dev"; then
    run mount -v --bind /dev "$ADM_ROOTFS/dev"
  else
    echo "   $ADM_ROOTFS/dev já montado (bind)."
  fi

  # devpts
  if ! is_mounted "$ADM_ROOTFS/dev/pts"; then
    run mkdir -pv "$ADM_ROOTFS/dev/pts"
    # gid=5,mode=620 é o padrão LFS; se seu host for diferente, ajuste se necessário
    run mount -vt devpts devpts "$ADM_ROOTFS/dev/pts" -o gid=5,mode=620
  else
    echo "   $ADM_ROOTFS/dev/pts já montado."
  fi

  # proc
  if ! is_mounted "$ADM_ROOTFS/proc"; then
    run mount -vt proc proc "$ADM_ROOTFS/proc"
  else
    echo "   $ADM_ROOTFS/proc já montado."
  fi

  # sysfs
  if ! is_mounted "$ADM_ROOTFS/sys"; then
    run mount -vt sysfs sysfs "$ADM_ROOTFS/sys"
  else
    echo "   $ADM_ROOTFS/sys já montado."
  fi

  # run (tmpfs)
  if ! is_mounted "$ADM_ROOTFS/run"; then
    run mount -vt tmpfs tmpfs "$ADM_ROOTFS/run"
  else
    echo "   $ADM_ROOTFS/run já montado."
  fi

  # /dev/shm
  if [ -h "$ADM_ROOTFS/dev/shm" ]; then
    run mkdir -pv "$ADM_ROOTFS/$(readlink "$ADM_ROOTFS/dev/shm")"
  else
    run mkdir -pv "$ADM_ROOTFS/dev/shm"
  fi
}

setup_resolv() {
  echo "==> Copiando /etc/resolv.conf para o chroot"
  run mkdir -pv "$ADM_ROOTFS/etc"

  if [ -f /etc/resolv.conf ]; then
    # -L segue symlink se o host usar resolv.conf gerenciado
    run cp -vL /etc/resolv.conf "$ADM_ROOTFS/etc/resolv.conf"
  else
    echo "AVISO: /etc/resolv.conf não existe no host; DNS pode falhar dentro do chroot."
  fi
}

setup_adm_mount_and_bin() {
  echo "==> Preparando adm dentro do chroot"

  # Bind-mount dos scripts do adm: ADM_ROOT (host) -> $ADM_ROOTFS/mnt/adm
  if [ -d "$ADM_ROOT" ]; then
    run mkdir -pv "$ADM_ROOTFS/mnt"
    run mkdir -pv "$ADM_ROOTFS/mnt/adm"
    if ! is_mounted "$ADM_ROOTFS/mnt/adm"; then
      run mount --bind "$ADM_ROOT" "$ADM_ROOTFS/mnt/adm"
    else
      echo "   $ADM_ROOTFS/mnt/adm já está montado (bind)."
    fi
  else
    echo "AVISO: Diretório ADM_ROOT=$ADM_ROOT não existe; scripts de build não estarão no chroot."
  fi

  # Copiar binário do adm para o sistema alvo
  if [ -n "$ADM_BIN" ] && [ -x "$ADM_BIN" ]; then
    run mkdir -pv "$ADM_ROOTFS/usr/local/bin"
    run cp -v "$ADM_BIN" "$ADM_ROOTFS/usr/local/bin/adm"
    run chmod 0755 "$ADM_ROOTFS/usr/local/bin/adm"
  else
    echo "AVISO: Binário 'adm' não encontrado (ADM_BIN=$ADM_BIN); só scripts estarão disponíveis."
  fi
}

bootstrap_in_chroot() {
  echo "==> Entrando no chroot (script interno) para criar diretórios e arquivos básicos"

  chroot "$ADM_ROOTFS" /usr/bin/env -i \
    HOME=/root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash -xe << 'EOF_CHROOT'

# ===== Dentro do chroot a partir daqui =====

echo "=== [chroot] Criando diretórios básicos (FHS-like) ==="

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
127.0.0.1  localhost adm-system
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

echo "=== [chroot] Bootstrap básico do sistema alvo concluído. ==="
EOF_CHROOT
}

do_setup() {
  need_root
  check_rootfs_dir
  setup_ownership
  setup_kernfs
  setup_resolv
  setup_adm_mount_and_bin
  bootstrap_in_chroot
  echo "==> Setup do chroot em $ADM_ROOTFS concluído."
}

# ---------- CLEANUP (host) ----------

do_cleanup() {
  need_root
  check_rootfs_dir

  echo "==> Desmontando mounts do chroot em ordem segura"

  # Ordem inversa da montagem:
  # 1) bind /mnt/adm
  if is_mounted "$ADM_ROOTFS/mnt/adm"; then
    run umount -v "$ADM_ROOTFS/mnt/adm"
  fi

  # 2) devpts
  if is_mounted "$ADM_ROOTFS/dev/pts"; then
    run umount -v "$ADM_ROOTFS/dev/pts"
  fi

  # 3) shm (se for mount separado; geralmente não é)
  if is_mounted "$ADM_ROOTFS/dev/shm"; then
    run umount -v "$ADM_ROOTFS/dev/shm"
  fi

  # 4) run, proc, sys, dev (nessa ordem)
  if is_mounted "$ADM_ROOTFS/run"; then
    run umount -v "$ADM_ROOTFS/run"
  fi
  if is_mounted "$ADM_ROOTFS/proc"; then
    run umount -v "$ADM_ROOTFS/proc"
  fi
  if is_mounted "$ADM_ROOTFS/sys"; then
    run umount -v "$ADM_ROOTFS/sys"
  fi
  if is_mounted "$ADM_ROOTFS/dev"; then
    run umount -v "$ADM_ROOTFS/dev"
  fi

  echo "==> Cleanup concluído. Montagens atuais:"
  show_status
}

# ---------- ENTER (host) ----------

do_enter() {
  need_root
  check_rootfs_dir

  # Faz setup mínimo se ainda não estiver montado
  if ! is_mounted "$ADM_ROOTFS/dev" || ! is_mounted "$ADM_ROOTFS/proc" || ! is_mounted "$ADM_ROOTFS/sys"; then
    echo "==> Ambiente de chroot ainda não montado; rodando setup primeiro."
    do_setup
  else
    # Garante bind do adm e resolv.conf atualizados
    setup_adm_mount_and_bin
    setup_resolv
  fi

  echo "==> Entrando no chroot. Ao sair do bash, farei cleanup automático."

  chroot "$ADM_ROOTFS" /usr/bin/env -i \
    HOME=/root \
    TERM="${TERM:-xterm}" \
    PS1="(${CHROOT_NAME} chroot) \u:\w\$ " \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
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
