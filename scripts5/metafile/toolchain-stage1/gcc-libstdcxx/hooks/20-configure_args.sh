#!/usr/bin/env sh
# Configura somente libstdc++-v3 (sem rebuild do GCC)

set -eu
: "${PREFIX:?PREFIX não definido}"

echo "--prefix=${PREFIX} --disable-multilib --disable-nls"
