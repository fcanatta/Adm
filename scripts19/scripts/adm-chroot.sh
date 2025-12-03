#!/usr/bin/env bash
# Cria e prepara um chroot LFS em /mnt/lfs (capítulo 7 completo o suficiente
# pra continuar a construir os pacotes temporários).
#
# Faz:
#   - ajusta ownership ($LFS) para root:root (7.2 Changing Ownership)
#   - monta /dev, /proc, /sys, /run, devpts, shm em $LFS (7.3 Kernfs)
#   - copia /etc/resolv.conf para $LFS/etc/resolv.conf
#   - copia o binário/script "adm" para dentro do chroot
#   - entra no chroot automaticamente para:
#       * criar diretórios (7.5 Creating Directories)
#       * criar /etc/passwd, /etc/group, /etc/hosts, /etc/mtab, logs (7.6)
#
# Depois disso você só precisa rodar:
#   chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" \
#       PS1='(lfs chroot) \u:\w\$ ' PATH=/usr/bin:/usr/sbin:/bin:/sbin \
#       /bin/bash --login

set -euo pipefail

LFS_DEFAULT="/mnt/lfs"
LFS="${LFS:-$LFS_DEFAULT}"

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

check_lfs() {
  if [ ! -d "$LFS" ]; then
    die "Diretório LFS ($LFS) não existe. Ex.: crie /mnt/lfs e monte a partição lá."
  fi
}

run() {
  echo "+ $*"
  "$@"
}

# ---------- 1. checagens ----------

need_root
check_lfs

echo "==> Usando LFS=$LFS"

# ---------- 2. Changing Ownership (cap. 7.2) ----------

echo "==> Ajustando ownership para root:root em diretórios chave do LFS"

for d in usr lib var etc bin sbin tools; do
  if [ -e "$LFS/$d" ]; then
    run chown -R root:root "$LFS/$d"
  fi
done

if [ -e "$LFS/lib64" ]; then
  run chown -R root:root "$LFS/lib64"
fi

# ---------- 3. Preparar virtual kernel filesystems (cap. 7.3) ----------

echo "==> Criando diretórios para /dev, /proc, /sys, /run dentro do LFS"

run mkdir -pv "$LFS"/{dev,proc,sys,run}

# /dev bind mount
if mountpoint -q "$LFS/dev"; then
  echo "==> $LFS/dev já está montado, pulando bind /dev"
else
  run mount -v --bind /dev "$LFS/dev"
fi

# devpts, proc, sysfs, tmpfs /run
if mountpoint -q "$LFS/dev/pts"; then
  echo "==> $LFS/dev/pts já está montado"
else
  run mkdir -pv "$LFS/dev/pts"
  run mount -vt devpts devpts "$LFS/dev/pts" -o gid=5,mode=620
fi

if mountpoint -q "$LFS/proc"; then
  echo "==> $LFS/proc já está montado"
else
  run mount -vt proc proc "$LFS/proc"
fi

if mountpoint -q "$LFS/sys"; then
  echo "==> $LFS/sys já está montado"
else
  run mount -vt sysfs sysfs "$LFS/sys"
fi

if mountpoint -q "$LFS/run"; then
  echo "==> $LFS/run já está montado"
else
  run mount -vt tmpfs tmpfs "$LFS/run"
fi

# /dev/shm inside chroot
if [ -h "$LFS/dev/shm" ]; then
  run mkdir -pv "$LFS/$(readlink "$LFS/dev/shm")"
else
  run mkdir -pv "$LFS/dev/shm"
fi

# ---------- 4. Copiar /etc/resolv.conf ----------

echo "==> Copiando /etc/resolv.conf para dentro do chroot"

run mkdir -pv "$LFS/etc"

if [ -f /etc/resolv.conf ]; then
  # -L para seguir symlink (como no livro)
  run cp -vL /etc/resolv.conf "$LFS/etc/resolv.conf"
else
  echo "AVISO: /etc/resolv.conf não existe no host – DNS pode não funcionar dentro do chroot."
fi

# ---------- 5. Copiar o adm para dentro do chroot ----------

echo "==> Copiando adm para dentro do chroot (se encontrado no PATH)"

ADM_BIN="${ADM_BIN:-$(command -v adm 2>/dev/null || true)}"

if [ -n "$ADM_BIN" ] && [ -x "$ADM_BIN" ]; then
  run mkdir -pv "$LFS/usr/local/bin"
  run cp -v "$ADM_BIN" "$LFS/usr/local/bin/adm"
  run chmod 0755 "$LFS/usr/local/bin/adm"
else
  echo "AVISO: comando 'adm' não encontrado no PATH; nada foi copiado."
  echo "       Exporte ADM_BIN=/caminho/do/adm e rode o script novamente se quiser copiá-lo."
fi

# ---------- 6. Rodar parte do capítulo 7 *dentro* do chroot ----------

echo "==> Entrando no chroot temporariamente para criar diretórios e arquivos essenciais"

if ! command -v chroot >/dev/null 2>&1; then
  die "Comando 'chroot' não encontrado no host."
fi

# Aqui usamos env -i para ambiente limpo, como no livro.
chroot "$LFS" /usr/bin/env -i \
  HOME=/root \
  PATH=/usr/bin:/usr/sbin:/bin:/sbin \
  /bin/bash -xe << 'EOF_CHROOT'

# ---------- dentro do chroot a partir daqui ----------

echo "=== [chroot] Criando diretórios do FHS (cap. 7.5) ==="

mkdir -pv /{boot,home,mnt,opt,srv}

mkdir -pv /etc/{opt,sysconfig}
mkdir -pv /lib/firmware
mkdir -pv /media/{floppy,cdrom}
mkdir -pv /usr/{,local/}{include,src}
mkdir -pv /usr/lib/locale
mkdir -pv /usr/local/{bin,lib,sbin}
mkdir -pv /usr/{,local/}share/{color,dict,doc,info,locale,man}
mkdir -pv /usr/{,local/}share/{misc,terminfo,zoneinfo}
mkdir -pv /usr/{,local/}share/man/man{1..8}
mkdir -pv /var/{cache,local,log,mail,opt,spool}
mkdir -pv /var/lib/{color,misc,locate}

ln -sfv /run /var/run
ln -sfv /run/lock /var/lock

install -dv -m 0750 /root
install -dv -m 1777 /tmp /var/tmp

echo "=== [chroot] Criando /etc/mtab (link para /proc/self/mounts) ==="
ln -svf /proc/self/mounts /etc/mtab

echo "=== [chroot] Criando /etc/hosts básico ==="
cat > /etc/hosts << "EOF_HOSTS"
127.0.0.1  localhost lfs
::1        localhost
EOF_HOSTS

echo "=== [chroot] Criando /etc/passwd se ainda não existir ==="
if [ ! -f /etc/passwd ]; then
  cat > /etc/passwd << "EOF_PASSWD"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF_PASSWD
else
  echo "    /etc/passwd já existe, não será sobrescrito."
fi

echo "=== [chroot] Criando /etc/group se ainda não existir ==="
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
else
  echo "    /etc/group já existe, não será sobrescrito."
fi

echo "=== [chroot] Criando arquivos de log vazios (btmp, faillog, lastlog, wtmp) ==="
touch /var/log/{btmp,faillog,lastlog,wtmp}
chgrp -v utmp /var/log/lastlog /var/log/wtmp || true
chmod -v 664 /var/log/{lastlog,wtmp}
chmod -v 600 /var/log/btmp
chmod -v 600 /var/log/faillog || true

echo "=== [chroot] Estado final dos logs ==="
ls -l /var/log

echo "=== [chroot] Setup básico do capítulo 7 concluído. ==="
EOF_CHROOT

echo "==> Chroot preparado com sucesso."

cat << EOF_DONE

========================================================
Chroot LFS pronto para o capítulo 7 em: $LFS

Para entrar no chroot e continuar a construir os programas:

  export LFS="$LFS"
  chroot "\$LFS" /usr/bin/env -i \\
      HOME=/root TERM="\$TERM" \\
      PS1='(lfs chroot) \\u:\\w\\$ ' \\
      PATH=/usr/bin:/usr/sbin:/bin:/sbin \\
      /bin/bash --login

Dentro do chroot, o 'adm' estará em /usr/local/bin/adm (se foi encontrado).
========================================================
EOF_DONE
