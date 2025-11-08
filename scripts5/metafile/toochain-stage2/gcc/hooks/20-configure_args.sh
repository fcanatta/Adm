#!/usr/bin/env sh
# Configuração do GCC final, nativo

set -eu
: "${PREFIX:?}"
: "${ADM_GCC_LANGS:=c,c++}"

common="--prefix=${PREFIX} \
 --enable-languages=${ADM_GCC_LANGS} \
 --disable-multilib --disable-werror --enable-default-pie \
 --enable-host-shared --enable-threads=posix \
 --with-system-zlib"

# Para musl, convém não forçar libsanitizer se não desejar:
# common="$common --disable-libsanitizer"

echo "$common"
