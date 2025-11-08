#!/usr/bin/env sh
# Imprime argumentos adicionais para o ./configure (uma linha)

set -eu

# Compat: alguns pipelines “sourcing” em vez de ler stdout; aqui só ecoamos
echo "${CONFIGURE_TARGET:-} ${CONFIGURE_SYSROOT:-} ${CONFIGURE_DISABLES:-} ${CONFIGURE_ENABLES:-} \
  --prefix=${PREFIX:?} --with-pic --disable-shared --enable-deterministic-archives"
