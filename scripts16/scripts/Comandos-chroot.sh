Como usar na prática

1. Preparar o chroot

export ADM_CHROOT=/mnt/lfs   # ou passe /mnt/lfs como segundo argumento
adm-chroot.sh prepare

Isso vai:

montar /dev, /dev/pts, /proc, /sys, /run;

garantir /usr/bin/adm dentro do chroot;

bind-mount /var/lib/adm, /var/log/adm, /var/tmp/adm/build.


2. Entrar no chroot e usar o adm

export ADM_CHROOT=/mnt/lfs
adm-chroot.sh enter

Dentro do chroot:

adm build cross-toolchain
adm build cross-toolchain-musl
adm install algum-pacote

3. Desmontar tudo quando terminar

export ADM_CHROOT=/mnt/lfs
adm-chroot.sh teardown
