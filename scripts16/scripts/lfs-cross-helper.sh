#!/usr/bin/env bash
# lfs-cross-helper.sh
# Helper independente para construir:
# - Cross-toolchain (Cap. 5)
# - Temporary tools (Cap. 6)
# - Chroot + ferramentas adicionais (Cap. 7)
# Alvo: LFS r12.4-46 (glibc), com opção de musl cross opcional

set -euo pipefail

###############################################################################
# CONFIGURAÇÃO GERAL
###############################################################################

: "${LFS:=/mnt/lfs}"
: "${LFS_USER:=lfs}"
: "${LFS_GROUP:=lfs}"
: "${JOBS:=$(nproc)}"
: "${LFS_TGT:=$(uname -m)-lfs-linux-gnu}"  # ex: x86_64-lfs-linux-gnu
: "${USE_MUSL:=0}"                         # 0 = usar Glibc, 1 = usar Musl no cross (opcional)

# Versões dos pacotes – atualize aqui quando sair nova versão
BINUTILS_VER=2.45.1
GCC_VER=15.2.0
MPFR_VER=4.2.2
GMP_VER=6.3.0
MPC_VER=1.3.1
LINUX_VER=6.17.8
GLIBC_VER=2.42
MUSL_VER=1.2.5

M4_VER=1.4.20
NCURSES_VER=6.5
BASH_VER=5.2.32
COREUTILS_VER=9.5
DIFFUTILS_VER=3.10
FILE_VER=5.46
FINDUTILS_VER=4.10.0
GAWK_VER=5.3.1
GREP_VER=3.11
GZIP_VER=1.13
MAKE_VER=4.4.1
PATCH_VER=2.7.6
SED_VER=4.9
TAR_VER=1.35
XZ_VER=5.6.2

GETTEXT_VER=0.26
BISON_VER=3.8.2
PERL_VER=5.42.0
PYTHON_VER=3.14.0
TEXINFO_VER=7.2
UTIL_LINUX_VER=2.41.2

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
    m4 make patch perl python3 sed tar xz wget
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
  mkdir -pv "$LFS"/{tools,usr,var,etc}
  # /bin, /lib, /sbin serão symlinks no sistema final; criamos depois no chroot
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
  chown -v "$LFS_USER":"$LFS_GROUP" "$LFS"/{usr,var,etc,tools}
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

  log "INIT-HOST pronto. Você pode copiar os tarballs para $SRC_DIR ou usar 'download-sources'."
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
    cd \"\$LFS/sources\"
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
# CAPÍTULO 5 – CROSS-TOOLCHAIN
#########################################################################

build_binutils_pass1() {
  run_as_lfs '
    set -e

    echo "=== BINUTILS-'"$BINUTILS_VER"' PASS 1: extraindo fonte ==="
    tar -xf binutils-'"$BINUTILS_VER"'.tar.xz
    cd binutils-'"$BINUTILS_VER"'

    mkdir -v build
    cd build

    echo "=== BINUTILS-'"$BINUTILS_VER"' PASS 1: configurando (cross) ==="
    ../configure \
      --prefix="$LFS/tools" \
      --with-sysroot="$LFS" \
      --target="$LFS_TGT" \
      --disable-nls \
      --enable-gprofng=no \
      --disable-werror

    make -j'"$JOBS"'
    make install

    cd "$LFS/sources"
    rm -rf binutils-'"$BINUTILS_VER"'
  '
}

build_gcc_pass1() {
  run_as_lfs '
    set -e

    echo "=== GCC-'"$GCC_VER"' PASS 1: extraindo fontes + dependências (mpfr/gmp/mpc) ==="
    tar -xf gcc-'"$GCC_VER"'.tar.xz
    cd gcc-'"$GCC_VER"'

    tar -xf ../mpfr-'"$MPFR_VER"'.tar.xz
    mv -v mpfr-'"$MPFR_VER"' mpfr
    tar -xf ../gmp-'"$GMP_VER"'.tar.xz
    mv -v gmp-'"$GMP_VER"' gmp
    tar -xf ../mpc-'"$MPC_VER"'.tar.gz
    mv -v mpc-'"$MPC_VER"' mpc

    case $(uname -m) in
      x86_64)
        sed -e "/m64=/s/lib64/lib/" -i.orig gcc/config/i386/t-linux64
      ;;
    esac

    mkdir -v build
    cd build

    echo "=== GCC-'"$GCC_VER"' PASS 1: configurando (cross) ==="
    ../configure \
      --target="$LFS_TGT" \
      --prefix="$LFS/tools" \
      --with-glibc-version='"$GLIBC_VER"' \
      --with-sysroot="$LFS" \
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
    rm -rf gcc-'"$GCC_VER"'
  '
}

build_linux_headers() {
  run_as_lfs '
    echo "=== LINUX-'"$LINUX_VER"': extraindo fonte (API headers) ==="
    tar -xf linux-'"$LINUX_VER"'.tar.xz
    cd linux-'"$LINUX_VER"'

    echo "=== LINUX-'"$LINUX_VER"': mrproper + headers ==="
    make mrproper
    make headers

    echo "=== LINUX-'"$LINUX_VER"': limpando arquivos que não são .h em usr/include ==="
    find usr/include -type f ! -name '"'"'*.h'"'"' -delete

    echo "=== LINUX-'"$LINUX_VER"': copiando usr/include para $LFS/usr ==="
    mkdir -p "$LFS/usr"
    cp -rv usr/include "$LFS/usr"

    echo "=== LINUX-'"$LINUX_VER"': limpeza ==="
    cd "$LFS/sources"
    rm -rf linux-'"$LINUX_VER"'
  '
}

build_glibc_cross() {
  run_as_lfs '
    echo "=== GLIBC-'"$GLIBC_VER"' (cross): extraindo fonte ==="
    tar -xf glibc-'"$GLIBC_VER"'.tar.xz
    cd glibc-'"$GLIBC_VER"'

    echo "=== GLIBC-'"$GLIBC_VER"' (cross): criando diretório build ==="
    mkdir -v build
    cd build

    echo "=== GLIBC-'"$GLIBC_VER"' (cross): configurando ==="
    ../configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build="$(../scripts/config.guess)" \
      --enable-kernel=4.19 \
      --with-headers="$LFS/usr/include" \
      libc_cv_slibdir=/usr/lib

    echo "=== GLIBC-'"$GLIBC_VER"' (cross): compilando ==="
    make -j'"$JOBS"'

    echo "=== GLIBC-'"$GLIBC_VER"' (cross): instalando no sysroot do LFS ==="
    make DESTDIR="$LFS" install

    echo "=== GLIBC-'"$GLIBC_VER"' (cross): limpeza ==="
    cd "$LFS/sources"
    rm -rf glibc-'"$GLIBC_VER"'
  '
}

build_libstdcpp_cross() {
  run_as_lfs '
    echo "=== LIBSTDC++ (GCC-'"$GCC_VER"' cross): extraindo fonte ==="
    tar -xf gcc-'"$GCC_VER"'.tar.xz
    cd gcc-'"$GCC_VER"'

    echo "=== LIBSTDC++ (GCC-'"$GCC_VER"' cross): criando diretório build-libstdc++ ==="
    mkdir -v build-libstdc++
    cd build-libstdc++

    echo "=== LIBSTDC++ (GCC-'"$GCC_VER"' cross): configurando libstdc++-v3 ==="
    ../libstdc++-v3/configure \
      --host="$LFS_TGT" \
      --build="$(../config.guess)" \
      --prefix=/usr \
      --disable-multilib \
      --disable-nls \
      --disable-libstdcxx-pch \
      --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/'"$GCC_VER"'

    echo "=== LIBSTDC++ (GCC-'"$GCC_VER"' cross): compilando ==="
    make -j'"$JOBS"'

    echo "=== LIBSTDC++ (GCC-'"$GCC_VER"' cross): instalando no sysroot do LFS ==="
    make DESTDIR="$LFS" install

    echo "=== LIBSTDC++ (GCC-'"$GCC_VER"' cross): limpeza ==="
    cd "$LFS/sources"
    rm -rf gcc-'"$GCC_VER"'
  '
}

build_musl_cross() {
  run_as_lfs '
    set -e

    echo "=== MUSL-'"$MUSL_VER"' (cross): extraindo fonte ==="
    tar -xf musl-'"$MUSL_VER"'.tar.gz
    cd musl-'"$MUSL_VER"'

    echo "=== MUSL-'"$MUSL_VER"' (cross): aplicando patches de segurança do iconv (se presentes) ==="
    if [ -f ../musl-'"$MUSL_VER"'-iconv-euckr.patch ]; then
      patch -Np1 -i ../musl-'"$MUSL_VER"'-iconv-euckr.patch
    fi
    if [ -f ../musl-'"$MUSL_VER"'-iconv-utf8-harden.patch ]; then
      patch -Np1 -i ../musl-'"$MUSL_VER"'-iconv-utf8-harden.patch
    fi

    echo "=== MUSL-'"$MUSL_VER"' (cross): configurando para alvo $LFS_TGT ==="
    CROSS_COMPILE="$LFS_TGT-" \
    ./configure \
      --prefix=/usr \
      --target="$LFS_TGT" \
      --syslibdir=/lib

    echo "=== MUSL-'"$MUSL_VER"' (cross): compilando ==="
    make -j'"$JOBS"'

    echo "=== MUSL-'"$MUSL_VER"' (cross): instalando no sysroot $LFS ==="
    make DESTDIR="$LFS" install

    echo "=== MUSL-'"$MUSL_VER"' (cross): limpeza ==="
    cd "$LFS/sources"
    rm -rf musl-'"$MUSL_VER"'
  '
}

phase_cross_toolchain() {
  need_root

  if ! phase_done init-host; then
    die "Você precisa rodar init-host antes de cross-toolchain."
  fi

  if ! phase_done verify-sources; then
    err "Aviso: verify-sources ainda não foi marcado como concluído."
    err "Recomendado rodar: $0 verify-sources"
  fi

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

  if [ "$USE_MUSL" -eq 1 ]; then
    log ">>> CAP. 5: Musl (cross) ..."
    build_musl_cross
  else
    log ">>> CAP. 5: Glibc (cross) ..."
    build_glibc_cross
  fi

  log ">>> CAP. 5: Libstdc++ (GCC '"$GCC_VER"') ..."
  build_libstdcpp_cross

  log ">>> Cross-toolchain concluída (Cap. 5)."
  mark_phase_done cross-toolchain
}

###############################################################################
# CAPÍTULO 6 – TEMPORARY TOOLS (Cross)
###############################################################################

build_m4() {
  run_as_lfs '
    set -e

    echo "=== M4-'"$M4_VER"': extraindo fonte ==="
    tar -xf m4-'"$M4_VER"'.tar.xz
    cd m4-'"$M4_VER"'

    echo "=== M4-'"$M4_VER"': configurando (host -> target cross) ==="
    ./configure \
        --prefix=/usr \
        --host="$LFS_TGT" \
        --build=$(build-aux/config.guess)

    echo "=== M4-'"$M4_VER"': compilando ==="
    make -j'"$JOBS"'

    echo "=== M4-'"$M4_VER"': instalando no sysroot do LFS ==="
    make DESTDIR="$LFS" install

    echo "=== M4-'"$M4_VER"': limpeza ==="
    cd "$LFS/sources"
    rm -rf m4-'"$M4_VER"'
  '
}

build_ncurses() {
  run_as_lfs '
    set -e
    echo "=== NCURSES-'"$NCURSES_VER"': extraindo fonte ==="
    tar -xf ncurses-'"$NCURSES_VER"'.tar.gz
    cd ncurses-'"$NCURSES_VER"'

    echo "=== NCURSES: preparando para cross-compilação ==="
    sed -i s/..mawk/..gawk/ configure || true

    mkdir -pv build
    pushd build
      ../configure
      make -C include
      make -C progs tic
    popd

    echo "=== NCURSES: configurando (host->target) ==="
    ./configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
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
    make DESTDIR="$LFS" TIC_PATH=build/progs/tic install

    echo "=== NCURSES: ajustando symlinks widec ==="
    echo "INPUT(-lncursesw)" > "$LFS/usr/lib/libncurses.so"

    echo "=== NCURSES: limpeza ==="
    cd "$LFS/sources"
    rm -rf ncurses-'"$NCURSES_VER"'
  '
}

build_bash() {
  run_as_lfs '
    set -e

    echo "=== BASH-'"$BASH_VER"' (temp tools): extraindo fonte ==="
    tar -xf bash-'"$BASH_VER"'.tar.gz
    cd bash-'"$BASH_VER"'

    ./configure \
      --prefix=/usr \
      --build=$(support/config.guess) \
      --host="$LFS_TGT" \
      --without-bash-malloc

    make -j'"$JOBS"'
    make DESTDIR="$LFS" install

    # Em merged-usr, sh vive em /usr/bin; /bin será symlink mais tarde
    ln -sv bash "$LFS/usr/bin/sh"

    cd "$LFS/sources"
    rm -rf bash-'"$BASH_VER"'
  '
}

build_coreutils() {
  run_as_lfs '
    set -e

    echo "=== COREUTILS-'"$COREUTILS_VER"' (temp tools): extraindo fonte ==="
    tar -xf coreutils-'"$COREUTILS_VER"'.tar.xz
    cd coreutils-'"$COREUTILS_VER"'

    ./configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build=$(build-aux/config.guess) \
      --enable-install-program=hostname \
      --enable-no-install-program=kill,uptime

    make -j'"$JOBS"'
    make DESTDIR="$LFS" install

    mv -v "$LFS/usr/bin/chroot" "$LFS/usr/sbin"
    mkdir -pv "$LFS/usr/share/man/man8"
    mv -v "$LFS/usr/share/man/man1/chroot.1" \
          "$LFS/usr/share/man/man8/chroot.8"
    sed -i 's/"1"/"8"/' "$LFS/usr/share/man/man8/chroot.8"

    cd "$LFS/sources"
    rm -rf coreutils-'"$COREUTILS_VER"'
  '
}

build_diffutils() {
  run_as_lfs '
    set -e

    echo "=== DIFFUTILS-'"$DIFFUTILS_VER"' (temp tools): extraindo fonte ==="
    tar -xf diffutils-'"$DIFFUTILS_VER"'.tar.xz
    cd diffutils-'"$DIFFUTILS_VER"'

    ./configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR="$LFS" install

    cd "$LFS/sources"
    rm -rf diffutils-'"$DIFFUTILS_VER"'
  '
}

build_file_6() {
  run_as_lfs '
    set -e

    echo "=== FILE-'"$FILE_VER"' (temp tools): extraindo fonte ==="
    tar -xf file-'"$FILE_VER"'.tar.gz
    cd file-'"$FILE_VER"'

    echo "=== FILE-'"$FILE_VER"': construindo file temporário no host (mesma versão) ==="
    mkdir build
    cd build

    ../configure --disable-bzlib --disable-libseccomp --disable-xzlib
    make -j'"$JOBS"'

    cd ..
    rm -rf build
    ./configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build=$(./config.guess)

    make -j'"$JOBS"'
    make DESTDIR="$LFS" install

    cd "$LFS/sources"
    rm -rf file-'"$FILE_VER"'
  '
}

build_findutils() {
  run_as_lfs '
    set -e

    echo "=== FINDUTILS-'"$FINDUTILS_VER"' (temp tools): extraindo fonte ==="
    tar -xf findutils-'"$FINDUTILS_VER"'.tar.xz
    cd findutils-'"$FINDUTILS_VER"'

    ./configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR="$LFS" install

    cd "$LFS/sources"
    rm -rf findutils-'"$FINDUTILS_VER"'
  '
}

build_gawk() {
  run_as_lfs '
    set -e

    echo "=== GAWK-'"$GAWK_VER"' (temp tools): extraindo fonte ==="
    tar -xf gawk-'"$GAWK_VER"'.tar.xz
    cd gawk-'"$GAWK_VER"'

    ./configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR="$LFS" install

    cd "$LFS/sources"
    rm -rf gawk-'"$GAWK_VER"'
  '
}

build_grep() {
  run_as_lfs '
    set -e

    echo "=== GREP-'"$GREP_VER"' (temp tools): extraindo fonte ==="
    tar -xf grep-'"$GREP_VER"'.tar.xz
    cd grep-'"$GREP_VER"'

    ./configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build=$(./build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR="$LFS" install

    cd "$LFS/sources"
    rm -rf grep-'"$GREP_VER"'
  '
}

build_gzip() {
  run_as_lfs '
    set -e

    echo "=== GZIP-'"$GZIP_VER"' (temp tools): extraindo fonte ==="
    tar -xf gzip-'"$GZIP_VER"'.tar.xz
    cd gzip-'"$GZIP_VER"'

    ./configure \
      --prefix=/usr \
      --host="$LFS_TGT"

    make -j'"$JOBS"'
    make DESTDIR="$LFS" install

    cd "$LFS/sources"
    rm -rf gzip-'"$GZIP_VER"'
  '
}

build_make() {
  run_as_lfs '
    set -e

    echo "=== MAKE-'"$MAKE_VER"' (temp tools): extraindo fonte ==="
    tar -xf make-'"$MAKE_VER"'.tar.gz
    cd make-'"$MAKE_VER"'

    ./configure \
      --prefix=/usr \
      --without-guile \
      --host="$LFS_TGT" \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR="$LFS" install

    cd "$LFS/sources"
    rm -rf make-'"$MAKE_VER"'
  '
}

build_patch() {
  run_as_lfs '
    set -e

    echo "=== PATCH-'"$PATCH_VER"' (temp tools): extraindo fonte ==="
    tar -xf patch-'"$PATCH_VER"'.tar.xz
    cd patch-'"$PATCH_VER"'

    ./configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR="$LFS" install

    cd "$LFS/sources"
    rm -rf patch-'"$PATCH_VER"'
  '
}

build_sed() {
  run_as_lfs '
    set -e

    echo "=== SED-'"$SED_VER"' (temp tools): extraindo fonte ==="
    tar -xf sed-'"$SED_VER"'.tar.xz
    cd sed-'"$SED_VER"'

    ./configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR="$LFS" install

    cd "$LFS/sources"
    rm -rf sed-'"$SED_VER"'
  '
}

build_tar_6() {
  run_as_lfs '
    set -e

    echo "=== TAR-'"$TAR_VER"' (temp tools): extraindo fonte ==="
    tar -xf tar-'"$TAR_VER"'.tar.xz
    cd tar-'"$TAR_VER"'

    ./configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build=$(build-aux/config.guess)

    make -j'"$JOBS"'
    make DESTDIR="$LFS" install

    cd "$LFS/sources"
    rm -rf tar-'"$TAR_VER"'
  '
}

build_xz_6() {
  run_as_lfs '
    set -e

    echo "=== XZ-'"$XZ_VER"' (temp tools): extraindo fonte ==="
    tar -xf xz-'"$XZ_VER"'.tar.xz
    cd xz-'"$XZ_VER"'

    ./configure \
      --prefix=/usr \
      --host="$LFS_TGT" \
      --build=$(build-aux/config.guess) \
      --disable-static      \
      --docdir=/usr/share/doc/xz-'"$XZ_VER"'

    make -j'"$JOBS"'
    make DESTDIR="$LFS" install

    cd "$LFS/sources"
    rm -rf xz-'"$XZ_VER"'
  '
}

phase_temp_tools() {
  need_root

  if ! phase_done cross-toolchain; then
    die "Você precisa concluir cross-toolchain (cap.5) antes de temp-tools (cap.6)."
  fi

  if phase_done temp-tools; then
    log "Fase temp-tools já foi concluída, pulando."
    return 0
  fi

  log ">>> CAP. 6: Temporary tools..."

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

  if ! phase_done temp-tools; then
    die "Você precisa concluir temp-tools (cap.6) antes de chroot-setup (cap.7)."
  fi

  if phase_done chroot-setup; then
    log "Fase chroot-setup já foi concluída, pulando."
    return 0
  fi

  log ">>> 7.2 Changing Ownership..."
  chown -R root:root "$LFS"/{usr,var,etc,tools}
  case "$(uname -m)" in
    x86_64)
      if [ -d "$LFS/lib64" ]; then
        chown -R root:root "$LFS/lib64"
      fi
    ;;
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
    set -e

    mkdir -pv /{boot,home,mnt,opt,srv}
    mkdir -pv /etc /media
    mkdir -pv /usr/{bin,lib,sbin,local}

    # Se /bin, /sbin, /lib existirem como diretórios (do host), remove para criar symlinks merged-usr
    for d in /bin /sbin /lib; do
      if [ -d "$d" ] && [ ! -L "$d" ]; then
        rm -rf "$d"
      fi
    done

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

    # link /bin/sh -> bash (temporary tools já instalaram bash em /usr/bin)
    ln -sfv bash /bin/sh
  '
}

###############################################################################
# CAPÍTULO 7 – FERRAMENTAS ADICIONAIS DENTRO DO CHROOT
###############################################################################

build_gettext_chroot() {
  run_in_chroot '
    set -e

    echo "=== Gettext-'"$GETTEXT_VER"' (chroot): extraindo fonte ==="
    tar -xf gettext-'"$GETTEXT_VER"'.tar.xz
    cd gettext-'"$GETTEXT_VER"'

    echo "=== Gettext-'"$GETTEXT_VER"' (chroot): configurando ==="
    ./configure --disable-shared

    echo "=== Gettext-'"$GETTEXT_VER"' (chroot): compilando ==="
    make

    echo "=== Gettext-'"$GETTEXT_VER"' (chroot): instalando msgfmt/msgmerge/xgettext ==="
    cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin

    echo "=== Gettext-'"$GETTEXT_VER"' (chroot): limpeza ==="
    cd /sources
    rm -rf gettext-'"$GETTEXT_VER"'
  '
}

build_bison_chroot() {
  run_in_chroot '
    set -e

    echo "=== Bison-'"$BISON_VER"' (chroot): extraindo fonte ==="
    tar -xf bison-'"$BISON_VER"'.tar.xz
    cd bison-'"$BISON_VER"'

    echo "=== Bison-'"$BISON_VER"' (chroot): configurando ==="
    ./configure --prefix=/usr \
                --docdir=/usr/share/doc/bison-'"$BISON_VER"'

    echo "=== Bison-'"$BISON_VER"' (chroot): compilando ==="
    make

    echo "=== Bison-'"$BISON_VER"' (chroot): instalando ==="
    make install

    echo "=== Bison-'"$BISON_VER"' (chroot): limpeza ==="
    cd /sources
    rm -rf bison-'"$BISON_VER"'
  '
}

build_perl_chroot() {
  run_in_chroot '
    set -e

    echo "=== Perl-'"$PERL_VER"' (chroot): extraindo fonte ==="
    tar -xf perl-'"$PERL_VER"'.tar.xz
    cd perl-'"$PERL_VER"'

    echo "=== Perl-'"$PERL_VER"' (chroot): configurando ==="
    sh Configure -des                                         \
                 -D prefix=/usr                               \
                 -D vendorprefix=/usr                         \
                 -D useshrplib                                \
                 -D privlib=/usr/lib/perl5/'"$PERL_VER"'/core_perl     \
                 -D archlib=/usr/lib/perl5/'"$PERL_VER"'/core_perl     \
                 -D sitelib=/usr/lib/perl5/'"$PERL_VER"'/site_perl     \
                 -D sitearch=/usr/lib/perl5/'"$PERL_VER"'/site_perl    \
                 -D vendorlib=/usr/lib/perl5/'"$PERL_VER"'/vendor_perl \
                 -D vendorarch=/usr/lib/perl5/'"$PERL_VER"'/vendor_perl

    echo "=== Perl-'"$PERL_VER"' (chroot): compilando ==="
    make

    echo "=== Perl-'"$PERL_VER"' (chroot): instalando ==="
    make install

    echo "=== Perl-'"$PERL_VER"' (chroot): limpeza ==="
    cd /sources
    rm -rf perl-'"$PERL_VER"'
  '
}

build_python_chroot() {
  run_in_chroot '
    set -e

    echo "=== Python-'"$PYTHON_VER"' (chroot): extraindo fonte ==="
    tar -xf Python-'"$PYTHON_VER"'.tar.xz
    cd Python-'"$PYTHON_VER"'

    echo "=== Python-'"$PYTHON_VER"' (chroot): configurando ==="
    ./configure --prefix=/usr   \
                --enable-shared \
                --without-ensurepip

    echo "=== Python-'"$PYTHON_VER"' (chroot): compilando ==="
    make

    echo "=== Python-'"$PYTHON_VER"' (chroot): instalando ==="
    make install

    echo "=== Python-'"$PYTHON_VER"' (chroot): limpeza ==="
    cd /sources
    rm -rf Python-'"$PYTHON_VER"'
  '
}

build_texinfo_chroot() {
  run_in_chroot '
    set -e

    echo "=== Texinfo-'"$TEXINFO_VER"' (chroot): extraindo fonte ==="
    tar -xf texinfo-'"$TEXINFO_VER"'.tar.xz
    cd texinfo-'"$TEXINFO_VER"'

    echo "=== Texinfo-'"$TEXINFO_VER"' (chroot): configurando ==="
    ./configure --prefix=/usr

    echo "=== Texinfo-'"$TEXINFO_VER"' (chroot): compilando ==="
    make

    echo "=== Texinfo-'"$TEXINFO_VER"' (chroot): instalando ==="
    make install

    echo "=== Texinfo-'"$TEXINFO_VER"' (chroot): limpeza ==="
    cd /sources
    rm -rf texinfo-'"$TEXINFO_VER"'
  '
}

build_utillinux_chroot() {
  run_in_chroot '
    set -e

    echo "=== Util-linux-'"$UTIL_LINUX_VER"' (chroot): extraindo fonte ==="
    tar -xf util-linux-'"$UTIL_LINUX_VER"'.tar.xz
    cd util-linux-'"$UTIL_LINUX_VER"'

    echo "=== Util-linux-'"$UTIL_LINUX_VER"' (chroot): criando /var/lib/hwclock ==="
    mkdir -pv /var/lib/hwclock

    echo "=== Util-linux-'"$UTIL_LINUX_VER"' (chroot): configurando ==="
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
                --docdir=/usr/share/doc/util-linux-'"$UTIL_LINUX_VER"'

    echo "=== Util-linux-'"$UTIL_LINUX_VER"' (chroot): compilando ==="
    make

    echo "=== Util-linux-'"$UTIL_LINUX_VER"' (chroot): instalando ==="
    make install

    echo "=== Util-linux-'"$UTIL_LINUX_VER"' (chroot): limpeza ==="
    cd /sources
    rm -rf util-linux-'"$UTIL_LINUX_VER"'
  '
}

phase_chroot_tools() {
  need_root

  if ! phase_done chroot-setup; then
    die "Você precisa concluir chroot-setup antes de chroot-tools."
  fi

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
  need_root
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
  wget -q -O md5sums \
    https://www.linuxfromscratch.org/lfs/downloads/development/md5sums

  echo
  echo "=== DOWNLOAD: Baixando todos os sources ==="
  echo

  wget \
    --input-file=wget-list \
    --continue \
    --directory-prefix="$LFS/sources" \
    --show-progress \
    --progress=bar:force:noscroll

  echo
  log "Fase download-sources concluída."
  mark_phase_done download-sources
  echo "=== DOWNLOAD: Concluído. Agora rode: $0 verify-sources ==="
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
  files_expected=$(awk '{ print $2 }' md5sums)

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

  log "Todos os sources conferem com os md5sums oficiais."
  mark_phase_done verify-sources
  echo "Todos os sources estão verificados e estão íntegros ✔️"
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
  cross-toolchain  – Binutils/GCC/Linux headers/Glibc/Musl/Libstdc++ (cap. 5)
  temp-tools       – temporary tools cross (cap. 6)
  chroot-setup     – ownership + mounts + diretórios + arquivos essenciais (cap. 7.2–7.6)
  chroot-tools     – gettext/bison/perl/python/texinfo/util-linux (cap. 7)
  enter-chroot     – entra em /bin/bash --login dentro do chroot
  umount-chroot    – desmonta /dev, /proc, /sys, /run do chroot (limpeza final)
  status           – mostra quais fases já foram concluídas (arquivo de estado)
  reset-state      – apaga o arquivo de estado para refazer fases
  all              – roda tudo na ordem (init-host → download-sources → verify-sources
                     → cross-toolchain → temp-tools → chroot-setup → chroot-tools
                     → enter-chroot)

Variáveis úteis:
  LFS        – caminho do sysroot (default: /mnt/lfs)
  LFS_TGT    – triplet alvo (ex: x86_64-lfs-linux-gnu)
  JOBS       – núcleos para make -j (default: nproc)
  USE_MUSL   – 0 = usar Glibc (default), 1 = usar Musl no cross-toolchain

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
  sudo USE_MUSL=1 $0 cross-toolchain
  sudo $0 status
  sudo $0 all
EOF
}

main() {
  local phase="${1:-}"
  case "${phase}" in
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
