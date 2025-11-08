#!/usr/bin/env sh
# Ambiente padrão p/ binutils stage2 (build nativo em /usr)

set -eu

# Biblioteca do perfil (impacta pequenas escolhas como "gold" e gprofng)
: "${ADM_PROFILE_LIBC:=glibc}"   # glibc|musl
arch="$(uname -m 2>/dev/null || echo x86_64)"

# Build nativo (sem TARGET forçado). Se quiser multi-alvo, exporte TARGET fora.
: "${PREFIX:=/usr}"
: "${DESTDIR:=/}"   # seu pipeline instala em DESTDIR; aqui default conservador
: "${SOURCE_DATE_EPOCH:=1704067200}"  # 2024-01-01
: "${CFLAGS:=-O2 -pipe}"
: "${CXXFLAGS:=${CFLAGS}}"
: "${MAKEFLAGS:=-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
export PREFIX DESTDIR SOURCE_DATE_EPOCH CFLAGS CXXFLAGS MAKEFLAGS

# Locale determinístico
export LC_ALL=C

# Detecta se vale habilitar gold por padrão (evita em musl por prudência)
enable_gold=1
[ "${ADM_PROFILE_LIBC}" = "musl" ] && enable_gold=0

# Exporta “sugestões” de features
export ADM_BINUTILS_ENABLE_GOLD="$enable_gold"
export ADM_BINUTILS_DISABLE_GPROFNG="$( [ "${ADM_PROFILE_LIBC}" = "musl" ] && echo 1 || echo 0 )"

# Em stage2, testes são opcionais (podem ser longos)
: "${ADM_RUN_TESTS:=0}"
export ADM_RUN_TESTS
