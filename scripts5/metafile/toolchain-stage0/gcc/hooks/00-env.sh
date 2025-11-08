#!/usr/bin/env sh
# Ambiente para GCC stage0 (cross, C-only, sem headers)

set -eu

# Raiz do LFS e sysroot do toolchain
: "${LFS:=/mnt/lfs}"
: "${SYSROOT:=${LFS}}"
export LFS SYSROOT

# Libc alvo do profile (só afeta o sufixo do target e desativa coisas)
: "${ADM_PROFILE_LIBC:=musl}"   # musl|glibc
arch="$(uname -m 2>/dev/null || echo x86_64)"
case "$arch" in
  x86_64) base_tgt="x86_64-lfs-linux";;
  aarch64) base_tgt="aarch64-lfs-linux";;
  riscv64) base_tgt="riscv64-lfs-linux";;
  *) base_tgt="${arch}-lfs-linux";;
esac
libcsfx="$( [ "$ADM_PROFILE_LIBC" = "musl" ] && echo musl || echo gnu )"
: "${LFS_TGT:=${base_tgt}-${libcsfx}}"
export LFS_TGT

# Prefix do toolchain de bootstrap
: "${PREFIX:=$LFS/tools}"
: "${DESTDIR:=$LFS}"   # instalação efetiva cai sob $LFS (sysroot)
export PREFIX DESTDIR

# PATH priorizando o toolchain (para pegar $LFS/tools/bin/{ar,as,ld,...})
if [ -d "$LFS/tools/bin" ]; then
  PATH="$LFS/tools/bin:$PATH"
fi
export PATH

# Flags mínimas e determinismo
: "${MAKEFLAGS:=-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
: "${SOURCE_DATE_EPOCH:=1704067200}"
export MAKEFLAGS SOURCE_DATE_EPOCH LC_ALL=C

# GCC stage0: só C; nada de threads/ssp/sanitizers/libstdc++
export ADM_GCC_LANGS="c"
