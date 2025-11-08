#!/usr/bin/env sh
# Define ambiente mínimo para stage0 do binutils

set -eu

# Deriva LFS e TARGET com defaults sensatos
: "${LFS:=/mnt/lfs}"
: "${ADM_PROFILE_LIBC:=glibc}"     # glibc|musl
arch="$(uname -m 2>/dev/null || echo x86_64)"

case "$arch" in
  x86_64) base_tgt="x86_64-lfs-linux";;
  aarch64) base_tgt="aarch64-lfs-linux";;
  riscv64) base_tgt="riscv64-lfs-linux";;
  *) base_tgt="${arch}-lfs-linux";;
esac

libcsfx="$( [ "${ADM_PROFILE_LIBC}" = "musl" ] && echo musl || echo gnu )"
: "${LFS_TGT:=${base_tgt}-${libcsfx}}"
export LFS LFS_TGT

# Se o pipeline já definiu TARGET, respeite; senão use LFS_TGT
: "${TARGET:=${LFS_TGT}}"
export TARGET

# SYSROOT padrão no LFS; em stage0 apontamos para $LFS
: "${SYSROOT:=${LFS}}"
export SYSROOT

# PATH priorizando ferramenta de bootstrap se existir
if [ -d "$LFS/tools/bin" ]; then
  PATH="$LFS/tools/bin:$PATH"
fi
export PATH

# Reprodutibilidade básica
: "${SOURCE_DATE_EPOCH:=1704067200}" # 2024-01-01
export SOURCE_DATE_EPOCH

# Flags conservadoras e determinísticas
: "${CFLAGS:=-O2 -pipe}"
: "${CXXFLAGS:=${CFLAGS}}"
: "${MAKEFLAGS:=-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
export CFLAGS CXXFLAGS MAKEFLAGS

# Prefix padrão para stage0 (apenas ferramentas de cross)
: "${PREFIX:=$LFS/tools}"
export PREFIX

# Saneamento de locale para evitar falhas em tests (se rodar)
export LC_ALL=C
