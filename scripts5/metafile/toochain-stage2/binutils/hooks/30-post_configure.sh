#!/usr/bin/env sh
# Ajustes pós-configure para estabilidade/reprodutibilidade

set -eu

# ARFLAGS com 'D' para timestamps determinísticos em alguns fluxos antigos
: "${ARFLAGS:=crD}"
export ARFLAGS
