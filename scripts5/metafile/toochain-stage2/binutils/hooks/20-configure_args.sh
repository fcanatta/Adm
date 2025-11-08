#!/usr/bin/env sh
# Emite os argumentos extras para ./configure (uma única linha)

set -eu

: "${CONFIGURE_COMMON:?CONFIGURE_COMMON não definido}"
echo "$CONFIGURE_COMMON"
