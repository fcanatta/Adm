#!/usr/bin/env bash
# Automatizador de LFS (r12.4-46) até o fim do capítulo 7
# ATENÇÃO:
#  - Rode como root no host.
#  - LFS DEVE estar em /mnt/lfs (ou exporte LFS antes).
#  - A partição já deve estar montada em $LFS.
#  - Todos os sources/patches devem estar em $LFS/sources.
#  - chmod +x /root/lfs-temp-tools-r12.4-46.sh e execute como root:
#  - LFS=/mnt/lfs /root/lfs-temp-tools-r12.4-46.sh
#
# USE POR SUA CONTA E RISCO. Leia o livro junto, sempre.

set -Eeuo pipefail

trap 'echo "[ERRO] Linha $LINENO: comando falhou. Verifique o log." >&2' ERR

LFS="${LFS:-/mnt/lfs}"
LOGDIR="${LOGDIR:-/var/log/lfs-temp-tools}"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/$(date +%F_%H-%M-%S)_lfs-temp-tools.log"

exec > >(tee -a "$LOGFILE") 2>&1

echo "=== LFS temp-tools builder (r12.4-46) ==="
echo "LFS = $LFS"
echo "Log  = $LOGFILE"

############################################
# Funções utilitárias
############################################

die() {
  echo "[FATAL] $*" >&2
  exit 1
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Este script precisa ser executado como root."
  fi
}

check_lfs_mount() {
  if [[ ! -d "$LFS" ]]; then
    die "Diretório $LFS não existe. Crie e monte a partição LFS primeiro."
  fi
  if ! mountpoint -q "$LFS"; then
    die "$LFS não está montado. Monte a partição (cap. 2) e exporte LFS."
  fi
}

check_sources_dir() {
  if [[ ! -d "$LFS/sources" ]]; then
    echo "Criando $LFS/sources ..."
    mkdir -pv "$LFS/sources"
    chmod -v a+wt "$LFS/sources"
  fi
}

############################################
# Cap. 4: Layout, usuário lfs, ambiente
############################################

setup_layout_and_tools() {
  echo ">>> [root] Criando layout básico em $LFS"

  mkdir -pv "$LFS"/{etc,var}
  mkdir -pv "$LFS"/usr/{bin,lib,sbin}

  for i in bin lib sbin; do
    if [[ ! -L "$LFS/$i" ]]; then
      ln -sv usr/$i "$LFS/$i" || true
    fi
  done

  if [[ "$(uname -m)" == "x86_64" ]]; then
    mkdir -pv "$LFS/lib64"
  fi

  mkdir -pv "$LFS/tools"
}

setup_lfs_user() {
  echo ">>> [root] Criando grupo/usuário lfs"

  if ! getent group lfs >/dev/null; then
    groupadd lfs
  fi

  if ! id lfs >/dev/null 2>&1; then
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs
  fi

  echo "Você pode definir senha pro usuário lfs depois com: passwd lfs"

  echo ">>> Ajustando permissões de $LFS"
  chown -v lfs "$LFS"/{usr,usr/*,var,etc,tools} 2>/dev/null || true
  if [[ "$(uname -m)" == "x86_64" ]]; then
    chown -v lfs "$LFS/lib64"
  fi

  echo ">>> Configurando .bash_profile e .bashrc do lfs"

  cat > /home/lfs/.bash_profile << 'EOF'
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF

  cat > /home/lfs/.bashrc << 'EOF'
set +h
umask 022
LFS=/mnt/lfs
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$LFS/tools/bin:$PATH
CONFIG_SITE=$LFS/usr/share/config.site
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
export MAKEFLAGS="-j$(nproc)"
EOF

  chown lfs:lfs /home/lfs/.bash_profile /home/lfs/.bashrc

  if [[ -e /etc/bash.bashrc ]]; then
    echo "Movendo /etc/bash.bashrc para /etc/bash.bashrc.NOUSE para evitar interferência..."
    mv -v /etc/bash.bashrc /etc/bash.bashrc.NOUSE || true
  fi
}

############################################
# Cap. 5 e 6: toolchain e temporary tools (como lfs)
############################################

build_toolchain_as_lfs() {
  echo ">>> [lfs] Construindo cross-toolchain e temporary tools (cap. 5 e 6)..."

  su - lfs << 'EOF_LFS'
set -Eeuo pipefail
trap 'echo "[ERRO LFS] Linha $LINENO"; exit 1' ERR

echo "=== Ambiente lfs ==="
echo "LFS     = $LFS"
echo "LFS_TGT = $LFS_TGT"
echo "PATH    = $PATH"

cd "$LFS/sources"

############################
# 5.2 Binutils-2.45.1 - Pass 1
############################
rm -rf binutils-2.45.1
tar -xf binutils-2.45.1.tar.xz
cd binutils-2.45.1

mkdir -v build
cd build

../configure --prefix=$LFS/tools \
             --with-sysroot=$LFS \
             --target=$LFS_TGT   \
             --disable-nls       \
             --enable-gprofng=no \
             --disable-werror    \
             --enable-new-dtags  \
             --enable-default-hash-style=gnu

make
make install

cd "$LFS/sources"
rm -rf binutils-2.45.1

############################
# 5.3 GCC-15.2.0 - Pass 1
############################
rm -rf gcc-15.2.0
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
    sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
  ;;
esac

mkdir -v build
cd build

../configure                  \
    --target=$LFS_TGT         \
    --prefix=$LFS/tools       \
    --with-glibc-version=2.42 \
    --with-sysroot=$LFS       \
    --with-newlib             \
    --without-headers         \
    --enable-default-pie      \
    --enable-default-ssp      \
    --disable-nls             \
    --disable-shared          \
    --disable-multilib        \
    --disable-threads         \
    --disable-libatomic       \
    --disable-libgomp         \
    --disable-libquadmath     \
    --disable-libssp          \
    --disable-libvtv          \
    --disable-libstdcxx       \
    --enable-languages=c,c++

make
make install

cd ..
cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
  \`dirname \$($LFS_TGT-gcc -print-libgcc-file-name)\`/include/limits.h

cd "$LFS/sources"
rm -rf gcc-15.2.0

############################
# 5.4 Linux-6.17.8 API Headers
############################
rm -rf linux-6.17.8
tar -xf linux-6.17.8.tar.xz
cd linux-6.17.8

make mrproper
make headers
find usr/include -type f ! -name '*.h' -delete
cp -rv usr/include "$LFS/usr"

cd "$LFS/sources"
rm -rf linux-6.17.8

############################
# 5.5 Glibc-2.42
############################
rm -rf glibc-2.42
tar -xf glibc-2.42.tar.xz
cd glibc-2.42

case $(uname -m) in
  i?86)   ln -sfv ld-linux.so.2 $LFS/lib/ld-lsb.so.3 ;;
  x86_64)
    ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64
    ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64/ld-lsb-x86-64.so.3
  ;;
esac

patch -Np1 -i ../glibc-2.42-fhs-1.patch

mkdir -v build
cd build

echo "rootsbindir=/usr/sbin" > configparms

../configure                             \
      --prefix=/usr                      \
      --host=$LFS_TGT                    \
      --build=$(../scripts/config.guess) \
      --disable-nscd                     \
      libc_cv_slibdir=/usr/lib           \
      --enable-kernel=5.4

make
make DESTDIR=$LFS install

sed '/RTLDLIST=/s@/usr@@g' -i $LFS/usr/bin/ldd

# Sanity checks (falham se algo estiver errado)
cd "$LFS/sources"
cd glibc-2.42/build

echo 'int main(){}' | $LFS_TGT-gcc -x c - -v -Wl,--verbose &> dummy.log
readelf -l a.out | grep ': /lib'
grep -E -o "$LFS/lib.*/S?crt[1in].*succeeded" dummy.log
grep -B3 "^ $LFS/usr/include" dummy.log
grep 'SEARCH.*/usr/lib' dummy.log | sed 's|; |\n|g'
grep "/lib.*/libc.so.6 " dummy.log
grep found dummy.log

rm -v a.out dummy.log

cd "$LFS/sources"
rm -rf glibc-2.42

############################
# 5.6 Libstdc++ (GCC-15.2.0)
############################
rm -rf gcc-15.2.0
tar -xf gcc-15.2.0.tar.xz
cd gcc-15.2.0

mkdir -v build
cd build

../libstdc++-v3/configure      \
    --host=$LFS_TGT            \
    --build=$(../config.guess) \
    --prefix=/usr              \
    --disable-multilib         \
    --disable-nls              \
    --disable-libstdcxx-pch    \
    --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/15.2.0

make
make DESTDIR=$LFS install

rm -v $LFS/usr/lib/lib{stdc++{,exp,fs},supc++}.la

cd "$LFS/sources"
rm -rf gcc-15.2.0

###########################################
# CAPÍTULO 6 — TEMPORARY TOOLS
###########################################

# 6.2 M4-1.4.20
rm -rf m4-1.4.20
tar -xf m4-1.4.20.tar.xz
cd m4-1.4.20

./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)

make
make DESTDIR=$LFS install

cd "$LFS/sources"
rm -rf m4-1.4.20

# 6.3 Ncurses-6.5-20250809
rm -rf ncurses-6.5-20250809
tar -xf ncurses-6.5-20250809.tar.xz
cd ncurses-6.5-20250809

mkdir build
pushd build
  ../configure --prefix=$LFS/tools AWK=gawk
  make -C include
  make -C progs tic
  install progs/tic $LFS/tools/bin
popd

./configure --prefix=/usr                \
            --host=$LFS_TGT              \
            --build=$(./config.guess)    \
            --mandir=/usr/share/man      \
            --with-manpage-format=normal \
            --with-shared                \
            --without-normal             \
            --with-cxx-shared            \
            --without-debug              \
            --without-ada                \
            --disable-stripping          \
            AWK=gawk

make
make DESTDIR=$LFS install
ln -sv libncursesw.so $LFS/usr/lib/libncurses.so
sed -e 's/^#if.*XOPEN.*$/#if 1/' \
    -i $LFS/usr/include/curses.h

cd "$LFS/sources"
rm -rf ncurses-6.5-20250809

# 6.4 Bash-5.3
rm -rf bash-5.3
tar -xf bash-5.3.tar.gz
cd bash-5.3

./configure --prefix=/usr                      \
            --build=$(sh support/config.guess) \
            --host=$LFS_TGT                    \
            --without-bash-malloc

make
make DESTDIR=$LFS install
ln -sv bash $LFS/bin/sh

cd "$LFS/sources"
rm -rf bash-5.3

# 6.5 Coreutils-9.9
rm -rf coreutils-9.9
tar -xf coreutils-9.9.tar.xz
cd coreutils-9.9

./configure --prefix=/usr                     \
            --host=$LFS_TGT                   \
            --build=$(build-aux/config.guess) \
            --enable-install-program=hostname \
            --enable-no-install-program=kill,uptime

make
make DESTDIR=$LFS install

mv -v $LFS/usr/bin/chroot              $LFS/usr/sbin
mkdir -pv $LFS/usr/share/man/man8
mv -v $LFS/usr/share/man/man1/chroot.1 $LFS/usr/share/man/man8/chroot.8
sed -i 's/"1"/"8"/'                    $LFS/usr/share/man/man8/chroot.8

cd "$LFS/sources"
rm -rf coreutils-9.9

# 6.6 Diffutils-3.12
rm -rf diffutils-3.12
tar -xf diffutils-3.12.tar.xz
cd diffutils-3.12

./configure --prefix=/usr   \
            --host=$LFS_TGT \
            gl_cv_func_strcasecmp_works=y \
            --build=$(./build-aux/config.guess)

make
make DESTDIR=$LFS install

cd "$LFS/sources"
rm -rf diffutils-3.12

# 6.7 File-5.46
rm -rf file-5.46
tar -xf file-5.46.tar.gz
cd file-5.46

mkdir build
pushd build
  ../configure --disable-bzlib      \
               --disable-libseccomp \
               --disable-xzlib      \
               --disable-zlib
  make
popd

./configure --prefix=/usr --host=$LFS_TGT --build=$(./config.guess)

make FILE_COMPILE=$(pwd)/build/src/file
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/libmagic.la

cd "$LFS/sources"
rm -rf file-5.46

# 6.8 Findutils-4.10.0
rm -rf findutils-4.10.0
tar -xf findutils-4.10.0.tar.xz
cd findutils-4.10.0

./configure --prefix=/usr                   \
            --localstatedir=/var/lib/locate \
            --host=$LFS_TGT                 \
            --build=$(build-aux/config.guess)

make
make DESTDIR=$LFS install

cd "$LFS/sources"
rm -rf findutils-4.10.0

# 6.9 Gawk-5.3.2
rm -rf gawk-5.3.2
tar -xf gawk-5.3.2.tar.xz
cd gawk-5.3.2

sed -i 's/extras//' Makefile.in

./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)

make
make DESTDIR=$LFS install

cd "$LFS/sources"
rm -rf gawk-5.3.2

# 6.10 Grep-3.12
rm -rf grep-3.12
tar -xf grep-3.12.tar.xz
cd grep-3.12

./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(./build-aux/config.guess)

make
make DESTDIR=$LFS install

cd "$LFS/sources"
rm -rf grep-3.12

# 6.11 Gzip-1.14
rm -rf gzip-1.14
tar -xf gzip-1.14.tar.xz
cd gzip-1.14

./configure --prefix=/usr --host=$LFS_TGT

make
make DESTDIR=$LFS install

cd "$LFS/sources"
rm -rf gzip-1.14

# 6.12 Make-4.4.1
rm -rf make-4.4.1
tar -xf make-4.4.1.tar.gz
cd make-4.4.1

./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)

make
make DESTDIR=$LFS install

cd "$LFS/sources"
rm -rf make-4.4.1

# 6.13 Patch-2.8
rm -rf patch-2.8
tar -xf patch-2.8.tar.xz
cd patch-2.8

./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)

make
make DESTDIR=$LFS install

cd "$LFS/sources"
rm -rf patch-2.8

# 6.14 Sed-4.9
rm -rf sed-4.9
tar -xf sed-4.9.tar.xz
cd sed-4.9

./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(./build-aux/config.guess)

make
make DESTDIR=$LFS install

cd "$LFS/sources"
rm -rf sed-4.9

# 6.15 Tar-1.35
rm -rf tar-1.35
tar -xf tar-1.35.tar.xz
cd tar-1.35

./configure --prefix=/usr   \
            --host=$LFS_TGT \
            --build=$(build-aux/config.guess)

make
make DESTDIR=$LFS install

cd "$LFS/sources"
rm -rf tar-1.35

# 6.16 Xz-5.8.1
rm -rf xz-5.8.1
tar -xf xz-5.8.1.tar.xz
cd xz-5.8.1

./configure --prefix=/usr                     \
            --host=$LFS_TGT                   \
            --build=$(build-aux/config.guess) \
            --disable-static                  \
            --docdir=/usr/share/doc/xz-5.8.1

make
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/liblzma.la

cd "$LFS/sources"
rm -rf xz-5.8.1

# 6.17 Binutils-2.45.1 - Pass 2
rm -rf binutils-2.45.1
tar -xf binutils-2.45.1.tar.xz
cd binutils-2.45.1

sed '6031s/$add_dir//' -i ltmain.sh

mkdir -v build
cd build

../configure                   \
    --prefix=/usr              \
    --build=$(../config.guess) \
    --host=$LFS_TGT            \
    --disable-nls              \
    --enable-shared            \
    --enable-gprofng=no        \
    --disable-werror           \
    --enable-64-bit-bfd        \
    --enable-new-dtags         \
    --enable-default-hash-style=gnu

make
make DESTDIR=$LFS install

rm -v $LFS/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}

cd "$LFS/sources"
rm -rf binutils-2.45.1

# 6.18 GCC-15.2.0 - Pass 2
rm -rf gcc-15.2.0
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
    sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
  ;;
esac

sed '/thread_header =/s/@.*@/gthr-posix.h/' \
    -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in

mkdir -v build
cd build

../configure                   \
    --build=$(../config.guess) \
    --host=$LFS_TGT            \
    --target=$LFS_TGT          \
    --prefix=/usr              \
    --with-build-sysroot=$LFS  \
    --enable-default-pie       \
    --enable-default-ssp       \
    --disable-nls              \
    --disable-multilib         \
    --disable-libatomic        \
    --disable-libgomp          \
    --disable-libquadmath      \
    --disable-libsanitizer     \
    --disable-libssp           \
    --disable-libvtv           \
    --enable-languages=c,c++   \
    LDFLAGS_FOR_TARGET=-L$PWD/$LFS_TGT/libgcc

make
make DESTDIR=$LFS install

ln -sv gcc $LFS/usr/bin/cc

cd "$LFS/sources"
rm -rf gcc-15.2.0

echo "=== Capítulos 5 e 6 concluídos como lfs ==="
EOF_LFS
}

############################################
# Cap. 7: chown, FS virtuais, chroot,
# ferramentas adicionais e limpeza
############################################

chapter7_pre_chroot_root() {
  echo ">>> [root] Cap. 7.2: Changing Ownership"

  chown --from lfs -R root:root $LFS/{usr,var,etc,tools}
  if [[ "$(uname -m)" == "x86_64" ]]; then
    chown --from lfs -R root:root $LFS/lib64
  fi

  echo ">>> [root] Cap. 7.3: Preparando FS virtuais"
  mkdir -pv $LFS/{dev,proc,sys,run}

  mount -v --bind /dev $LFS/dev
  mount -vt devpts devpts -o gid=5,mode=0620 $LFS/dev/pts
  mount -vt proc   proc   $LFS/proc
  mount -vt sysfs  sysfs  $LFS/sys
  mount -vt tmpfs  tmpfs  $LFS/run

  if [ -h $LFS/dev/shm ]; then
    install -v -d -m 1777 $LFS$(realpath /dev/shm)
  else
    mount -vt tmpfs -o nosuid,nodev tmpfs $LFS/dev/shm
  fi
}

chapter7_chroot_and_build() {
  echo ">>> [chroot] Entrando no ambiente e construindo ferramentas adicionais..."

  chroot "$LFS" /usr/bin/env -i \
    HOME=/root                  \
    TERM="$TERM"                \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin     \
    MAKEFLAGS="-j$(nproc)"      \
    /bin/bash --login << 'EOF_CHROOT'
set -Eeuo pipefail
trap 'echo "[ERRO CHROOT] Linha $LINENO"; exit 1' ERR

echo "=== Dentro do chroot LFS ==="
echo "PATH = $PATH"

################################
# 7.5 Criando diretórios finais
################################
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

################################
# 7.6 Arquivos essenciais
################################
ln -sv /proc/self/mounts /etc/mtab

cat > /etc/hosts << EOF
127.0.0.1  localhost $(hostname)
::1        localhost
EOF

cat > /etc/passwd << "EOF"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF

cat > /etc/group << "EOF"
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
clock:x:14:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
input:x:24:
mail:x:34:
kvm:x:61:
uuidd:x:80:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF

echo "tester:x:101:101::/home/tester:/bin/bash" >> /etc/passwd
echo "tester:x:101:" >> /etc/group
install -o tester -d /home/tester

# tira o "I have no name!"
exec /usr/bin/bash --login << 'EOF_CHROOT_SHELL'
set -Eeuo pipefail
trap 'echo "[ERRO CHROOT inner] Linha $LINENO"; exit 1' ERR

touch /var/log/{btmp,lastlog,faillog,wtmp}
chgrp -v utmp /var/log/lastlog
chmod -v 664  /var/log/lastlog
chmod -v 600  /var/log/btmp

################################
# 7.7 Gettext-0.26
################################
cd /sources
rm -rf gettext-0.26
tar -xf gettext-0.26.tar.xz
cd gettext-0.26

./configure --disable-shared
make
cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin

cd /sources
rm -rf gettext-0.26

################################
# 7.8 Bison-3.8.2
################################
rm -rf bison-3.8.2
tar -xf bison-3.8.2.tar.xz
cd bison-3.8.2

./configure --prefix=/usr \
            --docdir=/usr/share/doc/bison-3.8.2

make
make install

cd /sources
rm -rf bison-3.8.2

################################
# 7.9 Perl-5.42.0
################################
rm -rf perl-5.42.0
tar -xf perl-5.42.0.tar.xz
cd perl-5.42.0

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

make
make install

cd /sources
rm -rf perl-5.42.0

################################
# 7.10 Python-3.14.0
################################
rm -rf Python-3.14.0
tar -xf Python-3.14.0.tar.xz
cd Python-3.14.0

./configure --prefix=/usr       \
            --enable-shared     \
            --without-ensurepip \
            --without-static-libpython

make
make install

cd /sources
rm -rf Python-3.14.0

################################
# 7.11 Texinfo-7.2
################################
rm -rf texinfo-7.2
tar -xf texinfo-7.2.tar.xz
cd texinfo-7.2

./configure --prefix=/usr
make
make install

cd /sources
rm -rf texinfo-7.2

################################
# 7.12 Util-linux-2.41.2
################################
rm -rf util-linux-2.41.2
tar -xf util-linux-2.41.2.tar.xz
cd util-linux-2.41.2

mkdir -pv /var/lib/hwclock

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

make
make install

cd /sources
rm -rf util-linux-2.41.2

################################
# 7.13.1 Cleaning
################################
rm -rf /usr/share/{info,man,doc}/*
find /usr/{lib,libexec} -name '*.la' -delete
rm -rf /tools

echo "=== Cap. 7 até 7.13.1 concluído dentro do chroot ==="

EOF_CHROOT_SHELL
EOF_CHROOT
}

chapter7_unmount_and_backup() {
  local DO_BACKUP="${LFS_BACKUP:-1}"  # 1 = faz backup, 0 = pula

  echo ">>> [root host] Saindo do chroot, desmontando FS virtuais..."

  mountpoint -q $LFS/dev/shm && umount $LFS/dev/shm || true
  umount $LFS/dev/pts || true
  umount $LFS/{sys,proc,run,dev} || true

  if [[ "$DO_BACKUP" == "1" ]]; then
    echo ">>> Criando backup de $LFS para \$HOME/lfs-temp-tools-r12.4-46.tar.xz"
    cd "$LFS"
    tar -cJpf "$HOME/lfs-temp-tools-r12.4-46.tar.xz" .
    echo "Backup criado em $HOME/lfs-temp-tools-r12.4-46.tar.xz"
  else
    echo ">>> LFS_BACKUP=0 definido – pulando backup automático."
  fi
}

############################################
# MAIN
############################################

main() {
  check_root
  check_lfs_mount
  check_sources_dir

  setup_layout_and_tools
  setup_lfs_user

  build_toolchain_as_lfs

  chapter7_pre_chroot_root
  chapter7_chroot_and_build
  chapter7_unmount_and_backup

  echo
  echo "===================================================="
  echo " TEMPORARY SYSTEM (até 7.13) CONSTRUÍDO COM SUCESSO "
  echo " Log: $LOGFILE"
  echo " Backup (se habilitado) em: \$HOME/lfs-temp-tools-r12.4-46.tar.xz"
  echo " Agora siga para o capítulo 8 do livro."
  echo "===================================================="
}

main "$@"
