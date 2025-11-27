#!/usr/bin/env bash
# lfs-cross-helper.sh
# Helper independente para construir:
# - Cross-toolchain (Cap. 5)
# - Temporary tools (Cap. 6)
# - Chroot + ferramentas adicionais (Cap. 7)
# Alvo: LFS r12.4-46

set -euo pipefail

###############################################################################
# CONFIGURAÇÃO GERAL
###############################################################################

: "${LFS:=/mnt/lfs}"
: "${LFS_USER:=lfs}"
: "${LFS_GROUP:=lfs}"
: "${JOBS:=$(nproc)}"
: "${LFS_TGT:=$(uname -m)-lfs-linux-gnu}"  # ex: x86_64-lfs-linux-gnu

# Arquivo de estado para saber quais fases já foram concluídas
STATE_FILE="${STATE_FILE:-$LFS/.lfs-helper.state}"

phase_done() {
  local phase="$1"
  [ -f "$STATE_FILE" ] && grep -qx "$phase" "$STATE_FILE"
}

mark_phase_done() {
  local phase="$1"
  mkdir -p "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  # evita duplicata
  if ! grep -qx "$phase" "$STATE_FILE"; then
    echo "$phase" >> "$STATE_FILE"
  fi
}

show_status() {
  local phases=(
    init-host
    download-sources
    verify-sources
    cross-toolchain
    temp-tools
    chroot-setup
    chroot-tools
  )

  echo "=== Estado das fases (arquivo: $STATE_FILE) ==="
  for p in "${phases[@]}"; do
    if phase_done "$p"; then
      printf "  [OK]   %s\n" "$p"
    else
      printf "  [....] %s\n" "$p"
    fi
  done
}

reset_state() {
  if [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE"
    echo "Estado resetado (removido $STATE_FILE)."
  else
    echo "Nenhum arquivo de estado para remover."
  fi
}

# Diretório onde você coloca TODOS os tarballs do LFS
SRC_DIR="$LFS/sources"

log()  { printf '\n\033[1;32m[+] %s\033[0m\n' "$*"; }
err()  { printf '\n\033[1;31m[!] %s\033[0m\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Precisa rodar como root."
  fi
}

check_host_tools() {
  # Verifica rapidamente se o host possui as ferramentas básicas exigidas pelo LFS.
  # Não checa versões, apenas presença.
  local req_tools=(
    bash binutils bison coreutils diff find gawk gcc g++ grep gzip
    m4 make patch perl python3 sed tar xz
  )
  local missing=()

  for t in "${req_tools[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      missing+=("$t")
    fi
  done

  if [ "${#missing[@]}" -ne 0 ]; then
    err "Seu sistema host está faltando algumas ferramentas obrigatórias:"
    printf '  - %s\n' "${missing[@]}" >&2
    err "Instale os pacotes acima conforme o capítulo 2 do LFS e rode novamente."
    exit 1
  fi
}

###############################################################################
# AMBIENTE PARA O USUÁRIO lfs (cap. 4)
###############################################################################

phase_init_host() {
  need_root
  check_host_tools

  if phase_done init-host; then
    log "Fase init-host já foi concluída (marcada em $STATE_FILE), pulando."
    return 0
  fi
   
  log "Criando layout básico em $LFS..."
  mkdir -pv "$LFS"
  mkdir -pv "$SRC_DIR"
  chmod -v a+wt "$SRC_DIR"
  mkdir -pv "$LFS"/{tools,usr,bin,lib,sbin,var,etc}
  case "$(uname -m)" in
    x86_64) mkdir -pv "$LFS/lib64" ;;
  esac

  # RECOMENDADO: symlink /tools -> $LFS/tools (host)
  if [ ! -e /tools ]; then
    ln -sv "$LFS/tools" /tools
  fi

  log "Criando usuário/grupo $LFS_USER..."
  getent group "$LFS_GROUP" >/dev/null 2>&1 || groupadd "$LFS_GROUP"
  if ! id "$LFS_USER" >/dev/null 2>&1; then
    useradd -s /bin/bash -g "$LFS_GROUP" -m -k /dev/null "$LFS_USER"
  fi

  chown -v "$LFS_USER":"$LFS_GROUP" "$LFS"
  chown -v "$LFS_USER":"$LFS_GROUP" "$SRC_DIR"
  chown -v "$LFS_USER":"$LFS_GROUP" "$LFS"/{usr,bin,lib,sbin,var,etc,tools}
  if [ -d "$LFS/lib64" ]; then
    chown -v "$LFS_USER":"$LFS_GROUP" "$LFS/lib64"
  fi

  log "Configurando ambiente do $LFS_USER (cap. 4.4)..."
  cat > /home/"$LFS_USER"/.bash_profile << EOF
exec env -i HOME=\$HOME TERM=\$TERM PS1='\u:\w\$ ' /bin/bash
EOF

  cat > /home/"$LFS_USER"/.bashrc << EOF
set +h
umask 022
LFS=$LFS
export LFS
LFS_TGT=$LFS_TGT
export LFS_TGT
CONFIG_SITE=\$LFS/usr/share/config.site
export CONFIG_SITE
PATH=\$LFS/tools/bin:/usr/bin:/bin
export PATH
EOF

  chown "$LFS_USER":"$LFS_GROUP" /home/"$LFS_USER"/.bash_profile /home/"$LFS_USER"/.bashrc

  log "Fase init-host concluída."
  mark_phase_done init-host

  log "INIT-HOST pronto. Agora copie os tarballs para $SRC_DIR (cap. 3)."
}

###############################################################################
# HELPERS PARA rodar como lfs e dentro do chroot
###############################################################################

run_as_lfs() {
  local cmd="$*"
  su - "$LFS_USER" -c "
    set -e
    export LFS=\"$LFS\"
    export LFS_TGT=\"$LFS_TGT\"
    export CONFIG_SITE=\"\$LFS/usr/share/config.site\"
    export PATH=\"\$LFS/tools/bin:/usr/bin:/bin\"
    umask 022
    cd \$LFS/sources
    $cmd
  "
}

run_in_chroot() {
  local cmd="$*"
  chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="$TERM" PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin:/bin:/sbin \
    /usr/bin/bash -c "set -e; umask 022; cd /sources; $cmd"
}

#########################################################################
# CAPÍTULO 5 – CROSS-TOOLCHAIN (trechos omitidos no comentário)
#########################################################################

build_binutils_pass1() {
  run_as_lfs '
    set -e

    echo "=== BINUTILS-2.45.1 PASS 1: extraindo fonte ==="
    tar -xf binutils-2.45.1.tar.xz
    cd binutils-2.45.1

    mkdir -v build
    cd build

    echo "=== BINUTILS-2.45.1 PASS 1: configurando (cross) ==="
    ../configure \
      --prefix=$LFS/tools \
      --with-sysroot=$LFS \
      --target=$LFS_TGT \
      --disable-nls \
      --enable-gprofng=no \
      --disable-werror

    make -j'"$JOBS"'
    make install

    cd "$LFS/sources"
    rm -rf binutils-2.45.1
  '
}

build_gcc_pass1() {
  run_as_lfs '
    set -e

    echo "=== GCC-15.2.0 PASS 1: extraindo fontes + dependências (mpfr/gmp/mpc) ==="
    tar -xf gcc-15.2.0.tar.xz
    cd gcc-15.2.0

    tar -xf ../mpfr-4.2.2.tar.xz
    mv -v mpfr-4.2.2 mpfr
    tar -xf ../gmp-6.3.0.tar.xz
    mv -v gmp-6.3.0 gmp
    tar -xf ../mpc-1.3.1.tar.gz
    mv -v mpc-1.3.1 mpc

    case $(uname -m) in
      x86_64)
        sed -e "/m64=/s/lib64/lib/" -i.orig gcc/config/i386/t-linux64
      ;;
    esac

    mkdir -v build
    cd build

    echo "=== GCC-15.2.0 PASS 1: configurando (cross) ==="
    ../configure \
      --target=$LFS_TGT \
      --prefix=$LFS/tools \
      --with-glibc-version=2.42 \
      --with-sysroot=$LFS \
      --with-newlib \
      --without-headers \
      --enable-default-pie \
      --enable-default-ssp \
      --disable-nls \
      --disable-shared \
      --disable-multilib \
      --disable-threads \
      --disable-libatomic \
      --disable-libgomp \
      --disable-libquadmath \
      --disable-libssp \
      --disable-libvtv \
      --disable-libstdcxx \
      --enable-languages=c,c++

    make -j'"$JOBS"'
    make install

    cd "$LFS/sources"
    rm -rf gcc-15.2.0
  '
}

# (demais funções de CAP. 5: build_linux_headers, build_glibc_cross,
#  build_libstdcpp_cross etc. permanecem como no seu script original)

phase_cross_toolchain() {
  need_root

  if phase_done cross-toolchain; then
    log "Fase cross-toolchain já foi concluída, pulando."
    return 0
  fi

  log ">>> CAP. 5: Binutils pass 1..."
  build_binutils_pass1

  log ">>> CAP. 5: GCC pass 1..."
  build_gcc_pass1

  log ">>> CAP. 5: Linux API headers..."
  build_linux_headers

  log ">>> CAP. 5: Glibc (cross) ..."
  build_glibc_cross

  log ">>> CAP. 5: Libstdc++ (GCC 15.2) ..."
  build_libstdcpp_cross

  log ">>> Cross-toolchain concluída (Cap. 5)."
  mark_phase_done cross-toolchain
}

###############################################################################
# CAPÍTULO 6 – TEMPORARY TOOLS (Cross)
# Temporary tools do capítulo 6 já implementadas abaixo.
###############################################################################

build_m4() {
  run_as_lfs '
    set -e

    echo "=== M4-1.4.20: extraindo fonte ==="
    tar -xf m4-1.4.20.tar.xz
    cd m4-1.4.20

    echo "=== M4-1.4.20: configurando (host -> target cross) ==="
    ./configure \
        --prefix=/usr \
        --host=$LFS_TGT \
        --build=$(build-aux/config.guess)

    echo "=== M4-1.4.20: compilando ==="
    make -j'"$JOBS"'

    echo "=== M4-1.4.20: instalando no sysroot do LFS ==="
    make DESTDIR=$LFS install

    echo "=== M4-1.4.20: limpeza ==="
    cd "$LFS/sources"
    rm -rf m4-1.4.20
  '
}

build_ncurses() {
  run_as_lfs '
    set -e
    echo "=== NCURSES-6.x: extraindo fonte ==="
    tar -xf ncurses-6.5.tar.gz
    cd ncurses-6.5

    echo "=== NCURSES: preparando para cross-compilação ==="
    sed -i s/..mawk/..gawk/ configure

    mkdir -pv build
    pushd build
      ../configure
      make -C include
      make -C progs tic
    popd

    echo "=== NCURSES: configurando (host->target) ==="
    ./configure \
      --prefix=/usr \
      --host=$LFS_TGT \
      --build=$(./config.guess) \
      --mandir=/usr/share/man \
      --with-manpage-format=normal \
      --with-shared \
      --without-debug \
      --without-normal \
      --with-cxx-shared \
      --enable-pc-files \
      --enable-widec

    make -j'"$JOBS"'

    echo "=== NCURSES: instalando ==="
    make DESTDIR=$LFS TIC_PATH=build/progs/tic install

    echo "=== NCURSES: ajustando symlinks widec ==="
    echo "INPUT(-lncursesw)" > $LFS/usr/lib/libncurses.so

    echo "=== NCURSES: limpeza ==="
    cd "$LFS/sources"
    rm -rf ncurses-6.5
  '
}

build_bash() {
  run_as_lfs '
    set -e

    echo "=== BASH-5.2.32 (temp tools): extraindo fonte ==="
    tar -xf bash-5.2.32.tar.gz
    cd bash-5.2.32

    ./configure \
      --prefix=/usr \
      --build=$(support/config.guess) \
      --host=$LFS_TGT \
      --without-bash-malloc

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    ln -sv bash $LFS/bin/sh

    cd "$LFS/sources"
    rm -rf bash-5.2.32
  '
}

build_coreutils() {
  run_as_lfs '
    set -e

    echo "=== COREUTILS-9.5 (temp tools): extraindo fonte ==="
    tar -xf coreutils-9.5.tar.xz
    cd coreutils-9.5

    ./configure \
      --prefix=/usr \
      --host=$LFS_TGT \
      --build=$(build-aux/config.guess) \
      --enable-install-program=hostname \
      --enable-no-install-program=kill,uptime

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    mv -v $LFS/usr/bin/chroot $LFS/usr/sbin
    mkdir -pv $LFS/usr/share/man/man8
    mv -v $LFS/usr/share/man/man1/chroot.1 \
          $LFS/usr/share/man/man8/chroot.8
    sed -i 's/"1"/"8"/' $LFS/usr/share/man/man8/chroot.8

    cd "$LFS/sources"
    rm -rf coreutils-9.5
  '
}

build_diffutils() {
  run_as_lfs '
    set -e

    echo "=== DIFFUTILS-3.10 (temp tools): extraindo fonte ==="
    tar -xf diffutils-3.10.tar.xz
    cd diffutils-3.10

    ./configure \
      --prefix=/usr \
      --host=$LFS_TGT \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    cd "$LFS/sources"
    rm -rf diffutils-3.10
  '
}

build_file_6() {
  run_as_lfs '
    set -e

    echo "=== FILE-5.46 (temp tools): extraindo fonte ==="
    tar -xf file-5.46.tar.gz
    cd file-5.46

    echo "=== FILE-5.46: construindo file temporário no host (mesma versão) ==="
    mkdir build
    cd build

    ../configure --disable-bzlib --disable-libseccomp --disable-xzlib
    make -j'"$JOBS"'

    cd ..
    rm -rf build
    ./configure \
      --prefix=/usr \
      --host=$LFS_TGT \
      --build=$(./config.guess)

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    cd "$LFS/sources"
    rm -rf file-5.46
  '
}

build_findutils() {
  run_as_lfs '
    set -e

    echo "=== FINDUTILS-4.10.0 (temp tools): extraindo fonte ==="
    tar -xf findutils-4.10.0.tar.xz
    cd findutils-4.10.0

    ./configure \
      --prefix=/usr \
      --host=$LFS_TGT \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    cd "$LFS/sources"
    rm -rf findutils-4.10.0
  '
}

build_gawk() {
  run_as_lfs '
    set -e

    echo "=== GAWK-5.3.1 (temp tools): extraindo fonte ==="
    tar -xf gawk-5.3.1.tar.xz
    cd gawk-5.3.1

    ./configure \
      --prefix=/usr \
      --host=$LFS_TGT \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    cd "$LFS/sources"
    rm -rf gawk-5.3.1
  '
}

build_grep() {
  run_as_lfs '
    set -e

    echo "=== GREP-3.11 (temp tools): extraindo fonte ==="
    tar -xf grep-3.11.tar.xz
    cd grep-3.11

    ./configure \
      --prefix=/usr \
      --host=$LFS_TGT \
      --build=$(./build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    cd "$LFS/sources"
    rm -rf grep-3.11
  '
}

build_gzip() {
  run_as_lfs '
    set -e

    echo "=== GZIP-1.13 (temp tools): extraindo fonte ==="
    tar -xf gzip-1.13.tar.xz
    cd gzip-1.13

    ./configure \
      --prefix=/usr \
      --host=$LFS_TGT

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    cd "$LFS/sources"
    rm -rf gzip-1.13
  '
}

build_make() {
  run_as_lfs '
    set -e

    echo "=== MAKE-4.4.1 (temp tools): extraindo fonte ==="
    tar -xf make-4.4.1.tar.gz
    cd make-4.4.1

    ./configure \
      --prefix=/usr \
      --without-guile \
      --host=$LFS_TGT \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    cd "$LFS/sources"
    rm -rf make-4.4.1
  '
}

build_patch() {
  run_as_lfs '
    set -e

    echo "=== PATCH-2.7.6 (temp tools): extraindo fonte ==="
    tar -xf patch-2.7.6.tar.xz
    cd patch-2.7.6

    ./configure \
      --prefix=/usr \
      --host=$LFS_TGT \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    cd "$LFS/sources"
    rm -rf patch-2.7.6
  '
}

build_sed() {
  run_as_lfs '
    set -e

    echo "=== SED-4.9 (temp tools): extraindo fonte ==="
    tar -xf sed-4.9.tar.xz
    cd sed-4.9

    ./configure \
      --prefix=/usr \
      --host=$LFS_TGT \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    cd "$LFS/sources"
    rm -rf sed-4.9
  '
}

build_tar_6() {
  run_as_lfs '
    set -e

    echo "=== TAR-1.35 (temp tools): extraindo fonte ==="
    tar -xf tar-1.35.tar.xz
    cd tar-1.35

    ./configure \
      --prefix=/usr \
      --host=$LFS_TGT \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    cd "$LFS/sources"
    rm -rf tar-1.35
  '
}

build_xz_6() {
  run_as_lfs '
    set -e

    echo "=== XZ-5.6.2 (temp tools): extraindo fonte ==="
    tar -xf xz-5.6.2.tar.xz
    cd xz-5.6.2

    ./configure \
      --prefix=/usr \
      --host=$LFS_TGT \
      --build=$(build-aux/config.guess) \
      --disable-static      \
      --docdir=/usr/share/doc/xz-5.6.2

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    cd "$LFS/sources"
    rm -rf xz-5.6.2
  '
}

phase_temp_tools() {
  need_root

  if phase_done temp-tools; then
    log "Fase temp-tools já foi concluída, pulando."
    return 0
  fi  

  log ">>> CAP. 6: Temporary tools (você precisa completar os blocos de build)."

  build_m4
  build_ncurses
  build_bash
  build_coreutils
  build_diffutils
  build_file_6
  build_findutils
  build_gawk
  build_grep
  build_gzip
  build_make
  build_patch
  build_sed
  build_tar_6
  build_xz_6

  log "Temporary tools (cap. 6) concluídas."
  mark_phase_done temp-tools
}

###############################################################################
# FASE CHROOT SETUP – MONTAGEM E AJUSTES
###############################################################################

phase_chroot_setup() {
  need_root

  if phase_done chroot-setup; then
    log "Fase chroot-setup já foi concluída, pulando."
    return 0
  fi

  log ">>> 7.2 Changing Ownership..."
  chown -R root:root "$LFS"/{usr,lib,var,etc,bin,sbin,tools}
  case "$(uname -m)" in
    x86_64) chown -R root:root "$LFS/lib64" ;;
  esac

  log ">>> 7.3 Preparing Virtual Kernel File Systems..."
  mkdir -pv "$LFS"/{dev,proc,sys,run}
  mountpoint -q "$LFS/dev"     || mount --bind /dev "$LFS/dev"
  mkdir -pv "$LFS/dev/pts"
  mountpoint -q "$LFS/dev/pts" || mount -t devpts devpts "$LFS/dev/pts" -o gid=5,mode=620
  mountpoint -q "$LFS/proc"    || mount -t proc   proc   "$LFS/proc"
  mountpoint -q "$LFS/sys"     || mount -t sysfs  sysfs  "$LFS/sys"
  mountpoint -q "$LFS/run"     || mount -t tmpfs  tmpfs  "$LFS/run"

  if [ -h "$LFS/dev/shm" ]; then
    mkdir -pv "$LFS/$(readlink "$LFS/dev/shm")"
  fi

  # Agora entra no chroot e cria diretórios/arquivos essenciais
  phase_chroot_dirs_files

  log "Chroot setup (ownership + mounts + diretórios/arquivos essenciais) concluído."
  mark_phase_done chroot-setup
}

phase_chroot_dirs_files() {
  log ">>> 7.5/7.6 Creating Directories + Essential Files..."
  run_in_chroot '
    mkdir -pv /{boot,home,mnt,opt,srv}
    mkdir -pv /etc /media
    mkdir -pv /usr/{bin,lib,sbin,local}
    # Symlinks estilo FHS/merged-usr
    ln -sv usr/bin /bin
    ln -sv usr/sbin /sbin
    ln -sv usr/lib /lib

    mkdir -pv /var/{log,mail,spool}
    mkdir -pv /var/{opt,cache,lib/{misc,locate},local}
    mkdir -pv /var/log
    mkdir -pv /var/tmp

    install -dv -m 0750 /root
    install -dv -m 1777 /tmp /var/tmp

    # Arquivos essenciais /etc/passwd e /etc/group
    cat > /etc/passwd << "EOF"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
systemd-journal-gateway:x:73:73:systemd Journal Gateway:/:/usr/bin/false
systemd-journal-remote:x:74:74:systemd Journal Remote:/:/usr/bin/false
systemd-journal-upload:x:75:75:systemd Journal Upload:/:/usr/bin/false
systemd-network:x:76:76:systemd Network Management:/:/usr/bin/false
systemd-resolve:x:77:77:systemd Resolver:/:/usr/bin/false
systemd-timesync:x:78:78:systemd Time Synchronization:/:/usr/bin/false
systemd-coredump:x:79:79:systemd Core Dumper:/:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF

    cat > /etc/group << "EOF"
root:x:0:
bin:x:1:
daemon:x:6:
adm:x:16:
lp:x:7:
mail:x:12:
kmem:x:9:
wheel:x:10:
cdrom:x:11:
tape:x:13:
video:x:14:
audio:x:17:
utmp:x:22:
users:x:999:
nogroup:x:65534:
EOF

    # logindb básico
    touch /var/log/{wtmp,btmp,lastlog}
    chgrp -v utmp /var/log/lastlog || true
    chmod -v 664 /var/log/lastlog || true

    # link /bin/sh -> bash (temporary tools já instalaram bash)
    ln -sfv bash /bin/sh
  '
}

###############################################################################
# CAPÍTULO 7 – FERRAMENTAS ADICIONAIS DENTRO DO CHROOT
###############################################################################

build_gettext_chroot() {
  run_in_chroot '
    set -e

    echo "=== Gettext-0.26 (chroot): extraindo fonte ==="
    tar -xf gettext-0.26.tar.xz
    cd gettext-0.26

    echo "=== Gettext-0.26 (chroot): configurando ==="
    ./configure --disable-shared

    echo "=== Gettext-0.26 (chroot): compilando ==="
    make

    echo "=== Gettext-0.26 (chroot): instalando msgfmt/msgmerge/xgettext ==="
    cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin

    echo "=== Gettext-0.26 (chroot): limpeza ==="
    cd /sources
    rm -rf gettext-0.26
  '
}

build_bison_chroot() {
  run_in_chroot '
    set -e

    echo "=== Bison-3.8.2 (chroot): extraindo fonte ==="
    tar -xf bison-3.8.2.tar.xz
    cd bison-3.8.2

    echo "=== Bison-3.8.2 (chroot): configurando ==="
    ./configure --prefix=/usr \
                --docdir=/usr/share/doc/bison-3.8.2

    echo "=== Bison-3.8.2 (chroot): compilando ==="
    make

    echo "=== Bison-3.8.2 (chroot): instalando ==="
    make install

    echo "=== Bison-3.8.2 (chroot): limpeza ==="
    cd /sources
    rm -rf bison-3.8.2
  '
}

build_perl_chroot() {
  run_in_chroot '
    set -e

    echo "=== Perl-5.42.0 (chroot): extraindo fonte ==="
    tar -xf perl-5.42.0.tar.xz
    cd perl-5.42.0

    echo "=== Perl-5.42.0 (chroot): configurando ==="
    sh Configure -des                                         \
                 -D prefix=/usr                               \
                 -D vendorprefix=/usr                         \
                 -D useshrplib                                \
                 -D privlib=/usr/lib/perl5/5.42/core_perl     \
                 -D archlib=/usr/lib/perl5/5.42/core_perl     \
                 -D sitelib=/usr/lib/perl5/5.42/site_perl     \
                 -D sitearch=/usr/lib/perl5/5.42/site_perl    \
                 -D vendorlib=/usr/lib/perl5/5.42/vendor_perl \
                 -D vendorarch=/usr/lib/perl5/5.42/vendor_perl

    echo "=== Perl-5.42.0 (chroot): compilando ==="
    make

    echo "=== Perl-5.42.0 (chroot): instalando ==="
    make install

    echo "=== Perl-5.42.0 (chroot): limpeza ==="
    cd /sources
    rm -rf perl-5.42.0
  '
}

build_python_chroot() {
  run_in_chroot '
    set -e

    echo "=== Python-3.14.0 (chroot): extraindo fonte ==="
    tar -xf Python-3.14.0.tar.xz
    cd Python-3.14.0

    echo "=== Python-3.14.0 (chroot): configurando ==="
    ./configure --prefix=/usr   \
                --enable-shared \
                --without-ensurepip

    echo "=== Python-3.14.0 (chroot): compilando ==="
    make

    echo "=== Python-3.14.0 (chroot): instalando ==="
    make install

    echo "=== Python-3.14.0 (chroot): limpeza ==="
    cd /sources
    rm -rf Python-3.14.0
  '
}

build_texinfo_chroot() {
  run_in_chroot '
    set -e

    echo "=== Texinfo-7.2 (chroot): extraindo fonte ==="
    tar -xf texinfo-7.2.tar.xz
    cd texinfo-7.2

    echo "=== Texinfo-7.2 (chroot): configurando ==="
    ./configure --prefix=/usr

    echo "=== Texinfo-7.2 (chroot): compilando ==="
    make

    echo "=== Texinfo-7.2 (chroot): instalando ==="
    make install

    echo "=== Texinfo-7.2 (chroot): limpeza ==="
    cd /sources
    rm -rf texinfo-7.2
  '
}

build_utillinux_chroot() {
  run_in_chroot '
    set -e

    echo "=== Util-linux-2.41.2 (chroot): extraindo fonte ==="
    tar -xf util-linux-2.41.2.tar.xz
    cd util-linux-2.41.2

    echo "=== Util-linux-2.41.2 (chroot): criando /var/lib/hwclock ==="
    mkdir -pv /var/lib/hwclock

    echo "=== Util-linux-2.41.2 (chroot): configurando ==="
    ./configure --libdir=/usr/lib     \
                --runstatedir=/run    \
                --disable-chfn-chsh   \
                --disable-login       \
                --disable-nologin     \
                --disable-su          \
                --disable-setpriv     \
                --disable-runuser     \
                --disable-pylibmount  \
                --disable-static      \
                --disable-liblastlog2 \
                --without-python      \
                ADJTIME_PATH=/var/lib/hwclock/adjtime \
                --docdir=/usr/share/doc/util-linux-2.41.2

    echo "=== Util-linux-2.41.2 (chroot): compilando ==="
    make

    echo "=== Util-linux-2.41.2 (chroot): instalando ==="
    make install

    echo "=== Util-linux-2.41.2 (chroot): limpeza ==="
    cd /sources
    rm -rf util-linux-2.41.2
  '
}

phase_chroot_tools() {
  need_root

  if phase_done chroot-tools; then
    log "Fase chroot-tools já foi concluída, pulando."
    return 0
  fi

  log ">>> CAP. 7: ferramentas adicionais dentro do chroot..."

  build_gettext_chroot
  build_bison_chroot
  build_perl_chroot
  build_python_chroot
  build_texinfo_chroot
  build_utillinux_chroot

  log "Ferramentas adicionais de chroot (cap. 7) concluídas."
  mark_phase_done chroot-tools
}

###############################################################################
# FASE FINAL – ENTRAR NO CHROOT / DESMONTAR
###############################################################################

phase_enter_chroot_shell() {
  log "Entrando no chroot LFS. Daqui pra frente o adm assume com recipes normais."
  run_in_chroot '/bin/bash --login'
}


phase_unmount_chroot() {
  need_root

  log "Desmontando sistemas de arquivos virtuais do chroot em $LFS..."

  # Desmonta em ordem do mais profundo para o mais superficial
  for m in dev/pts dev/shm dev proc sys run; do
    if mountpoint -q "$LFS/$m"; then
      umount "$LFS/$m" || err "Falha ao desmontar $LFS/$m (verifique processos usando o mountpoint)."
    fi
  done

  log "Desmontagem de chroot concluída (se havia algo montado)."
}

###############################################################################
# DOWNLOAD E VERIFICAÇÃO DE SOURCES
###############################################################################

download_sources() {
  need_root

  if phase_done download-sources; then
    log "Fase download-sources já foi concluída, pulando."
    return 0
  fi
  
    echo "=== DOWNLOAD: Preparando diretório $LFS/sources ==="
    mkdir -pv "$LFS/sources"
    chmod -v a+wt "$LFS/sources"

    cd "$LFS/sources"

    echo "=== DOWNLOAD: Obtendo wget-list-sysv ==="
    wget -q -O wget-list \
      https://www.linuxfromscratch.org/lfs/downloads/development/wget-list

    echo "=== DOWNLOAD: Obtendo lista de md5sums oficial ==="
    # md5sums "cru" (ajuste para development / versão específica se preferir)
    wget -q -O md5sums \
      https://www.linuxfromscratch.org/lfs/downloads/development/md5sums

    echo
    echo "=== DOWNLOAD: Baixando todos os sources ==="
    echo

    # Barra de progresso do próprio wget
    #   --show-progress           -> mostra barra mesmo em stdout
    #   --progress=bar:force:noscroll -> barra contínua tipo apt
    wget \
      --input-file=wget-list \
      --continue \
      --directory-prefix="$LFS/sources" \
      --show-progress \
      --progress=bar:force:noscroll

    echo
    log "Fase download-sources concluída."
    mark_phase_done download-sources
    echo "=== DOWNLOAD: Concluído. Agora rode: helper verify-sources ==="
}

verify_sources() {
  need_root

  if phase_done verify-sources; then
    log "Fase verify-sources já foi concluída, pulando."
    return 0
  fi  


    cd "$LFS/sources" || die "Diretório $LFS/sources não existe."

    if [ ! -f md5sums ]; then
        die "Arquivo md5sums não encontrado em $LFS/sources. Rode primeiro: download-sources"
    fi

    echo "=== VERIFY: Verificando integridade com md5sum ==="
    md5sum -c md5sums > md5sum.log 2>&1 || true

    local ok fail missing count_ok count_fail count_missing

    ok=$(grep -E ": OK$" md5sum.log || true)
    fail=$(grep -E ": FAILED$" md5sum.log || true)

    count_ok=$(printf "%s" "$ok" | grep -c . || true)
    count_fail=$(printf "%s" "$fail" | grep -c . || true)

    # Descobrir quais arquivos o md5sums espera
    local files_expected
    files_expected=$(awk "{ print \$2 }" md5sums)

    missing=""
    count_missing=0
    for f in $files_expected; do
        if [ ! -f "$f" ]; then
            missing="$missing $f"
            count_missing=$((count_missing+1))
        fi
    done

    echo
    echo "================ RESULTADO MD5 ================"
    echo "OK       : $count_ok"
    echo "FALHOU   : $count_fail"
    echo "FALTANDO : $count_missing"
    echo "Log completo: $LFS/sources/md5sum.log"
    echo "==============================================="
    echo

    if [ "$count_fail" -gt 0 ] || [ "$count_missing" -gt 0 ]; then
        [ "$count_fail" -gt 0 ] && {
            echo "Arquivos com checksum incorreto:"
            echo "$fail"
            echo
        }
        [ "$count_missing" -gt 0 ] && {
            echo "Arquivos faltando:"
            echo "$missing"
            echo
        }
        echo "Corrija (apagando e baixando de novo) e rode 'verify-sources' novamente."
        return 1
    fi

    # Se tudo OK no final:
  log "Todos os sources conferem com os md5sums oficiais."
  mark_phase_done verify-sources

    echo "Todos os sources estão verificados e estão íntegros ✔️ "
}

###############################################################################
# USO / CLI
###############################################################################

usage() {
  cat << EOF
Uso: $0 <fase>

Fases:
  init-host        – cria layout \$LFS, usuário lfs, env (cap. 4)
  download-sources – baixa a wget-list e todos os sources para \$LFS/sources
  verify-sources   – verifica md5 dos sources em \$LFS/sources
  cross-toolchain  – Binutils/GCC/Linux headers/Glibc/Libstdc++ (cap. 5)
  temp-tools       – temporary tools cross (cap. 6)
  chroot-setup     – ownership + mounts + diretórios + arquivos essenciais (cap. 7.2–7.6)
  chroot-tools     – gettext/bison/perl/python/texinfo/util-linux (cap. 7)
  enter-chroot     – entra em /bin/bash --login dentro do chroot
  umount-chroot    – desmonta /dev, /proc, /sys, /run do chroot (limpeza final)
  status           – mostra quais fases já foram concluídas (arquivo de estado)
  reset-state      – apaga o arquivo de estado para refazer fases
  all              – roda tudo na ordem (init-host → download-sources → verify-sources → cross-toolchain 
                     → temp-tools → chroot-setup → chroot-tools → enter-chroot)

Exemplos:
  sudo $0 init-host
  sudo $0 download-sources
  sudo $0 verify-sources
  sudo $0 cross-toolchain
  sudo $0 temp-tools
  sudo $0 chroot-setup
  sudo $0 chroot-tools
  sudo $0 enter-chroot
  sudo $0 umount-chroot
  sudo $0 status
  sudo $0 all
EOF
}

main() {
  local phase="${1:-}"
  case "${1:-}" in
    init-host)        phase_init_host ;;
    download-sources) download_sources ;;
    verify-sources)   verify_sources ;;
    cross-toolchain)  phase_cross_toolchain ;;
    temp-tools)       phase_temp_tools ;;
    chroot-setup)     phase_chroot_setup ;;
    chroot-tools)     phase_chroot_tools ;;
    enter-chroot)     phase_enter_chroot_shell ;;
    umount-chroot)    phase_unmount_chroot ;;
    status)           show_status ;;
    reset-state)      reset_state ;;
    all)
      phase_init_host
      download_sources
      verify_sources
      phase_cross_toolchain
      phase_temp_tools
      phase_chroot_setup
      phase_chroot_tools
      phase_enter_chroot_shell
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
