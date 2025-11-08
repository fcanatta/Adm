#!/usr/bin/env sh
# Emite a linha de argumentos para ./configure (GCC cross, C-only, sem headers)

set -eu

: "${PREFIX:?}"
: "${SYSROOT:?}"
: "${LFS_TGT:?}"
: "${ADM_PROFILE_LIBC:=musl}"
: "${ADM_GCC_LANGS:=c}"

# Flags padrão para stage0 "sem headers"
common="--target=${LFS_TGT} --prefix=${PREFIX} \
 --with-sysroot=${SYSROOT} --with-build-sysroot=${SYSROOT} \
 --with-newlib --without-headers \
 --disable-nls --disable-shared --disable-bootstrap --disable-multilib \
 --disable-threads --disable-libatomic --disable-libgomp --disable-libquadmath \
 --disable-libssp --disable-libvtv --disable-libstdcxx --disable-decimal-float \
 --enable-languages=${ADM_GCC_LANGS}"

# Ajustes específicos para musl/glibc
if [ "${ADM_PROFILE_LIBC}" = "musl" ]; then
  # Evita checagens de glibc e desabilita sanitizers dependentes de glibc
  common="$common --disable-libsanitizer --with-native-system-header-dir=/usr/include"
else
  # glibc: geralmente ok; ainda sem headers reais aqui
  :
fi

echo "$common"
