#!/usr/bin/env bash
# GCC PASS2 (MUSL): C/C++ completos, sem libs problemáticas com musl
set -Eeuo pipefail

: "${LC_ALL:=C}"; export LC_ALL
: "${TZ:=UTC}"; export TZ
: "${SOURCE_DATE_EPOCH:=1700000000}"; export SOURCE_DATE_EPOCH

: "${TARGET:=}"; : "${PREFIX:=/usr}"; : "${SYSROOT:=/}"
if [[ -z "${TARGET}" ]]; then
  echo "[gcc-pass2] ERRO: TARGET não definido (ex.: x86_64-linux-musl)." >&2
  exit 2
fi

# Flags estáveis p/ destino
export CFLAGS_FOR_TARGET="${CFLAGS_FOR_TARGET:--O2 -pipe}"
export CXXFLAGS_FOR_TARGET="${CXXFLAGS_FOR_TARGET:--O2 -pipe}"
# Passes de bootstrap (se o builder quiser) — irrelevantes aqui, mas não atrapalham
export BOOT_CFLAGS="${BOOT_CFLAGS:--O2 -pipe}"

# Evita componentes complexos que costumam falhar com musl em estágios iniciais
# (sanitizers/itm/vtv/quadmath raramente são necessários no toolchain base)
CONF=(
  --target="${TARGET}"
  --prefix="${PREFIX}"
  --with-sysroot="${SYSROOT}"
  --with-native-system-header-dir=/usr/include
  --disable-multilib
  --disable-nls
  --enable-languages=c,c++
  --enable-shared
  --enable-threads=posix
  --disable-libsanitizer
  --disable-libvtv
  --disable-libitm
  --disable-libquadmath
)

# Se quiser forçar PIE por padrão (opcional), descomente:
# CONF+=( --enable-default-pie )

export CONFIGURE_OPTS="${CONFIGURE_OPTS:-} ${CONF[*]}"

# Targets make padrão (tudo e instala tudo)
export MAKE_TARGETS="${MAKE_TARGETS:-all}"
export MAKE_INSTALL_TARGETS="${MAKE_INSTALL_TARGETS:-install}"

# Prioriza binutils do target no PATH
if [[ -d "${PREFIX}/bin" ]]; then
  export PATH="${PREFIX}/bin:${PATH}"
fi

echo "[gcc-pass2] CONFIGURE_OPTS=${CONFIGURE_OPTS}"
echo "[gcc-pass2] MAKE_TARGETS=${MAKE_TARGETS}; MAKE_INSTALL_TARGETS=${MAKE_INSTALL_TARGETS}"
