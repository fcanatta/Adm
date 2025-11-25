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

Comando final funcionando

Agora você pode rodar:

adm chroot-build-group /mnt/lfs cross-toolchain

Isso faz:

1. Entrar no chroot /mnt/lfs


2. Preparar o ambiente


3. Rodar lá dentro:

adm build-group cross-toolchain


4. Usar automaticamente todas as variáveis ADM_* do host


5. Construir somente os pacotes necessários pela lógica de dependências + versão atual
