#!/usr/bin/env bash
# GCC PASS1: cross/minimal, gera 'gcc' e 'libgcc' do TARGET sem depender de glibc/musl ainda
set -Eeuo pipefail

: "${LC_ALL:=C}"; export LC_ALL
: "${TZ:=UTC}"; export TZ
: "${SOURCE_DATE_EPOCH:=1700000000}"; export SOURCE_DATE_EPOCH

: "${TARGET:=}"; : "${PREFIX:=}"; : "${SYSROOT:=}"
if [[ -z "${TARGET}" || -z "${PREFIX}" ]]; then
  echo "[gcc-pass1] AVISO: TARGET/PREFIX não definidos; modo host pass1 é incomum." >&2
fi

# Flags estáveis; PASS1 geralmente sem LTO/SSP/threads
export BOOT_CFLAGS="${BOOT_CFLAGS:--O2 -pipe}"
export CFLAGS_FOR_TARGET="${CFLAGS_FOR_TARGET:--O2 -pipe}"
export CXXFLAGS_FOR_TARGET="${CXXFLAGS_FOR_TARGET:--O2 -pipe}"

CONF=(
  ${TARGET:+--target="${TARGET}"}
  ${PREFIX:+--prefix="${PREFIX}"}
  ${SYSROOT:+--with-sysroot="${SYSROOT}"}
  --without-headers
  --with-newlib
  --disable-nls
  --disable-shared
  --disable-threads
  --disable-libatomic
  --disable-libgomp
  --disable-libquadmath
  --disable-libssp
  --disable-libvtv
  --disable-multilib
  --disable-libstdcxx
  --enable-languages=c
)
export CONFIGURE_OPTS="${CONFIGURE_OPTS:-} ${CONF[*]}"

# Passar alvos de make específicos do pass1:
# - compila o front-end gcc e a libgcc do TARGET
export MAKE_TARGETS="${MAKE_TARGETS:-all-gcc all-target-libgcc}"
export MAKE_INSTALL_TARGETS="${MAKE_INSTALL_TARGETS:-install-gcc install-target-libgcc}"

# PATH priorizando o binutils do TARGET recém-instalado (pass1)
if [[ -n "${PREFIX}" && -d "${PREFIX}/bin" ]]; then
  export PATH="${PREFIX}/bin:${PATH}"
fi

echo "[gcc-pass1] CONFIGURE_OPTS=${CONFIGURE_OPTS}"
echo "[gcc-pass1] MAKE_TARGETS=${MAKE_TARGETS}; MAKE_INSTALL_TARGETS=${MAKE_INSTALL_TARGETS}"
