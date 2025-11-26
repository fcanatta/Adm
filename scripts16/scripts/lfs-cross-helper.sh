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

###############################################################################
# AMBIENTE PARA O USUÁRIO lfs (cap. 4)
###############################################################################

phase_init_host() {
  need_root

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
  getent group "$LFS_GROUP" >/dev/null 2>&1 || groupadd -g 1001 "$LFS_GROUP"
  if ! id "$LFS_USER" >/dev/null 2>&1; then
    useradd -s /bin/bash -g "$LFS_GROUP" -m -k /dev/null "$LFS_USER"
  fi

  chown -v "$LFS_USER":"$LFS_GROUP" "$SRC_DIR"

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
    /bin/bash -c "set -e; umask 022; cd /sources; $cmd"
}

###############################################################################
# CAPÍTULO 5 – CROSS TOOLCHAIN
###############################################################################

build_binutils_pass1() {
  run_as_lfs '
    tar -xf binutils-2.45.1.tar.xz
    cd binutils-2.45.1

    mkdir -v build
    cd build

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
    tar -xf gcc-15.2.0.tar.xz
    cd gcc-15.2.0

    # (Opcional: extrair e linkar mpfr, gmp, mpc dentro de gcc como manda o livro)
    # tar -xf ../mpfr-*.tar.xz
    # mv -v mpfr-* mpfr
    # tar -xf ../gmp-*.tar.xz
    # mv -v gmp-* gmp
    # tar -xf ../mpc-*.tar.gz
    # mv -v mpc-* mpc

    case $(uname -m) in
      x86_64) sed -e "/m64=/s/lib64/lib/" -i.orig gcc/config/i386/t-linux64 ;;
    esac

    mkdir -v build
    cd build

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
      --disable-decimal-float \
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

build_linux_headers() {
  run_as_lfs '
    tar -xf linux-6.17.8.tar.xz
    cd linux-6.17.8

    make mrproper
    make headers
    find usr/include -name ".*" -delete
    rm -rf usr/include/Makefile
    mkdir -p $LFS/usr
    cp -rv usr/include $LFS/usr

    cd "$LFS/sources"
    rm -rf linux-6.17.8
  '
}

build_glibc_cross() {
  run_as_lfs '
    tar -xf glibc-2.42.tar.xz
    cd glibc-2.42

    mkdir -v build
    cd build

    ../configure \
      --prefix=/usr \
      --host=$LFS_TGT \
      --build=$(../scripts/config.guess) \
      --enable-kernel=4.19 \
      --with-headers=$LFS/usr/include \
      libc_cv_slibdir=/usr/lib

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    # Ajuste do linker (ld-linux etc.) se necessário (ver seção do livro)

    cd "$LFS/sources"
    rm -rf glibc-2.42
  '
}

build_libstdcpp_cross() {
  run_as_lfs '
    tar -xf gcc-15.2.0.tar.xz
    cd gcc-15.2.0

    mkdir -v build-libstdc++
    cd build-libstdc++

    ../libstdc++-v3/configure \
      --host=$LFS_TGT \
      --build=$(../config.guess) \
      --prefix=/usr \
      --disable-multilib \
      --disable-nls \
      --disable-libstdcxx-pch \
      --with-gxx-include-dir=/usr/include/c++/15.2.0

    make -j'"$JOBS"'
    make DESTDIR=$LFS install

    cd "$LFS/sources"
    rm -rf gcc-15.2.0
  '
}

phase_cross_toolchain() {
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

  log "Cross-toolchain concluída (Cap. 5)."
}

###############################################################################
# CAPÍTULO 6 – TEMPORARY TOOLS (Cross)
# Aqui deixo as funções declaradas, você cola o bloco do livro em cada uma.
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
        --build=$(./config.guess)

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
    echo "=== NCURSES-6.5-20250809: extraindo fonte ==="
    tar -xf ncurses-6.5-20250809.tar.xz
    cd ncurses-6.5-20250809

    # Evita depender de mawk em alguns hosts
    sed -i s/mawk// configure

    mkdir -v build
    cd build

    echo "=== NCURSES-6.5-20250809: configurando (temporary, wide-char, shared) ==="
    ../configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build="$(../config.guess)" \
      --mandir=/usr/share/man \
      --with-manpage-format=normal \
      --with-shared \
      --without-debug \
      --without-normal \
      --without-cxx-binding \
      --enable-widec \
      --enable-pc-files \
      --with-pkg-config-libdir=/usr/lib/pkgconfig

    echo "=== NCURSES-6.5-20250809: compilando ==="
    make -j'"$JOBS"'

    echo "=== NCURSES-6.5-20250809: instalando no sysroot do LFS ==="
    make DESTDIR="$LFS" install

    # Ajuste simples: pkg-config aponta pra ncursesw (wide)
    echo "=== NCURSES-6.5-20250809: ajuste de .pc para wide ==="
    sed -i "s@/usr/include@/usr/include/ncursesw@g" "$LFS/usr/lib/pkgconfig/ncursesw.pc"

    echo "=== NCURSES-6.5-20250809: limpeza ==="
    cd "$LFS/sources"
    rm -rf ncurses-6.5-20250809
  '
}
build_bash() {
  run_as_lfs '
    set -e
    echo "=== BASH-5.3: extraindo fonte ==="
    tar -xf bash-5.3.tar.gz
    cd bash-5.3

    echo "=== BASH-5.3: configurando (temporary tool) ==="
    ./configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build="$(support/config.guess)" \
      --without-bash-malloc

    echo "=== BASH-5.3: compilando ==="
    make -j'"$JOBS"'

    echo "=== BASH-5.3: instalando no sysroot do LFS ==="
    make DESTDIR="$LFS" install

    # Não mexemos em /bin/sh aqui; o link é criado depois, já dentro do chroot.
    echo "=== BASH-5.3: limpeza ==="
    cd "$LFS/sources"
    rm -rf bash-5.3
  '
}
build_coreutils()  { run_as_lfs '# COLE AQUI os comandos da seção 6.5 Coreutils-9.9'; }
build_diffutils()  { run_as_lfs '# COLE AQUI os comandos da seção 6.6 Diffutils-3.12'; }
build_file_6()     { run_as_lfs '# COLE AQUI os comandos da seção 6.7 File-5.46'; }
build_findutils()  { run_as_lfs '# COLE AQUI os comandos da seção 6.8 Findutils-4.10.0'; }
build_gawk()       { run_as_lfs '# COLE AQUI os comandos da seção 6.9 Gawk-5.3.2'; }
build_grep()       { run_as_lfs '# COLE AQUI os comandos da seção 6.10 Grep-3.12'; }
build_gzip()       { run_as_lfs '# COLE AQUI os comandos da seção 6.11 Gzip-1.14'; }
build_make()       { run_as_lfs '# COLE AQUI os comandos da seção 6.12 Make-4.4.1'; }
build_patch()      { run_as_lfs '# COLE AQUI os comandos da seção 6.13 Patch-2.8'; }
build_sed()        { run_as_lfs '# COLE AQUI os comandos da seção 6.14 Sed-4.9'; }
build_tar()        { run_as_lfs '# COLE AQUI os comandos da seção 6.15 Tar-1.35'; }
build_xz()         { run_as_lfs '# COLE AQUI os comandos da seção 6.16 Xz-5.8.1'; }
build_binutils_p2(){ run_as_lfs '# COLE AQUI os comandos da seção 6.17 Binutils-2.45.1 Pass 2'; }
build_gcc_p2()     { run_as_lfs '# COLE AQUI os comandos da seção 6.18 GCC-15.2.0 Pass 2'; }

phase_temp_tools() {
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
  build_tar
  build_xz
  build_binutils_p2
  build_gcc_p2

  log "Temporary tools do Cap. 6 concluídos."
}

###############################################################################
# CAPÍTULO 7 – CHROOT: OWNERSHIP, MOUNTS, DIRETÓRIOS, ARQUIVOS ESSENCIAIS
###############################################################################

phase_chroot_setup() {
  need_root

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

  log ">>> 7.4 Entering chroot (para criar dirs/arquivos e compilar ferramentas de chroot)..."
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
    case "$(uname -m)" in
      x86_64) ln -sv lib /lib64 ;;
    esac
    mkdir -pv /var/{log,mail,spool,run,cache,lib/{misc,locate}}
    mkdir -pv /root
    chmod 0750 /root

    # IMPORTANTE: /tmp e /var/tmp com sticky bit
    mkdir -pv /tmp /var/tmp
    chmod 1777 /tmp /var/tmp
    
    cat > /etc/passwd << "EOF"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
nobody:x:99:99:Unprivileged User:/dev/null:/usr/bin/false
EOF

    cat > /etc/group << "EOF"
root:x:0:
bin:x:1:
daemon:x:6:
sys:x:3:
adm:x:4:
tty:x:5:
disk:x:8:
lp:x:7:
mail:x:12:
kmem:x:9:
wheel:x:10:
cdrom:x:11:
tape:x:13:
video:x:14:
audio:x:17:
users:x:999:
nogroup:x:65534:
EOF

    echo "127.0.0.1  localhost" > /etc/hosts
    echo "LFS" > /etc/hostname

    ln -sv /proc/self/mounts /etc/mtab

    touch /var/log/{btmp,lastlog,wtmp}
    chmod -v 600 /var/log/btmp
    chmod -v 664 /var/log/lastlog

    # link /bin/sh -> bash (temporary tools já instalaram bash)
    ln -sfv bash /bin/sh
  '
}

###############################################################################
# CAPÍTULO 7 – FERRAMENTAS ADICIONAIS DENTRO DO CHROOT
###############################################################################

build_gettext_chroot() {
  run_in_chroot '# COLE AQUI os comandos da seção 7.7 Gettext-0.26'
}

build_bison_chroot() {
  run_in_chroot '# COLE AQUI os comandos da seção 7.8 Bison-3.8.2'
}

build_perl_chroot() {
  run_in_chroot '# COLE AQUI os comandos da seção 7.9 Perl-5.42.0'
}

build_python_chroot() {
  run_in_chroot '# COLE AQUI os comandos da seção 7.10 Python-3.14.0'
}

build_texinfo_chroot() {
  run_in_chroot '# COLE AQUI os comandos da seção 7.11 Texinfo-7.2'
}

build_utillinux_chroot() {
  run_in_chroot '# COLE AQUI os comandos da seção 7.12 Util-linux-2.41.2'
}

phase_chroot_tools() {
  log ">>> CAP. 7: ferramentas adicionais dentro do chroot..."

  build_gettext_chroot
  build_bison_chroot
  build_perl_chroot
  build_python_chroot
  build_texinfo_chroot
  build_utillinux_chroot

  log "Ferramentas adicionais de chroot (cap. 7) concluídas."
}

###############################################################################
# FASE FINAL – ENTRAR NO CHROOT PARA O ADM ASSUMIR
###############################################################################

phase_enter_chroot_shell() {
  log "Entrando no chroot LFS. Daqui pra frente o adm assume com recipes normais."
  run_in_chroot '/bin/bash --login'
}

###############################################################################
# FASE DOWNLOAD SOURCES – FAZ DOWNLOAD DE TODOS OS SOURCES
###############################################################################

download_sources() {
    need_root

    echo "=== DOWNLOAD: Preparando diretório $LFS/sources ==="
    mkdir -pv "$LFS/sources"
    chmod -v a+wt "$LFS/sources"

    cd "$LFS/sources"

    echo "=== DOWNLOAD: Obtendo wget-list-sysv ==="
    wget -q -O wget-list-sysv \
      https://www.linuxfromscratch.org/lfs/view/development/wget-list-sysv

    echo "=== DOWNLOAD: Obtendo lista de md5sums oficial ==="
    # md5sums "cru" (ajuste para stable / versão específica se preferir)
    wget -q -O md5sums \
      https://www.linuxfromscratch.org/lfs/downloads/stable/md5sums

    echo
    echo "=== DOWNLOAD: Baixando todos os sources com barra de progresso ==="
    echo

    # Barra de progresso “bonita” do próprio wget
    #   --show-progress           -> mostra barra mesmo em stdout
    #   --progress=bar:force:noscroll -> barra contínua tipo apt
    wget \
      --input-file=wget-list-sysv \
      --continue \
      --directory-prefix="$LFS/sources" \
      --show-progress \
      --progress=bar:force:noscroll

    echo
    echo "=== DOWNLOAD: Concluído. Agora rode: helper verify-sources ==="
}

verify_sources() {
    need_root

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
    files_expected=$(awk "{print \$2}" md5sums)

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

    echo "Todos os sources conferem com os md5sums oficiais. 👍"
}

###############################################################################
# DISPATCH
###############################################################################

usage() {
  cat << EOF
Uso: $0 <fase>

Fases:
  init-host       – cria layout $LFS, usuário lfs, env (cap. 4)
  download-sources – baixa wget-list-sysv e todos os sources
  verify-sources   – verifica md5 dos sources em $LFS/sources
  cross-toolchain – Binutils/GCC/Linux headers/Glibc/Libstdc++ (cap. 5)
  temp-tools      – temporary tools cross (cap. 6) – precisa colar comandos
  chroot-setup    – ownership + mounts + diretórios + arquivos essenciais (cap. 7.2–7.6)
  chroot-tools    – gettext/bison/perl/python/texinfo/util-linux (cap. 7) – colar comandos
  enter-chroot    – entra em /bin/bash --login dentro do chroot
  all             – roda tudo na ordem (init-host → cross-toolchain → temp-tools → chroot-setup → chroot-tools → enter-chroot)

Exemplos:
  sudo $0 init-host
  sudo $0 cross-toolchain
  sudo $0 temp-tools
  sudo $0 chroot-setup
  sudo $0 chroot-tools
  sudo $0 enter-chroot
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
  chroot-setup)
      phase_chroot_setup
      phase_chroot_dirs_files
      ;;
  chroot-tools)     phase_chroot_tools ;;
  enter-chroot)     phase_enter_chroot_shell ;;
  all)
      phase_init_host
      download_sources
      verify_sources
      phase_cross_toolchain
      phase_temp_tools
      phase_chroot_setup
      phase_chroot_dirs_files
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
