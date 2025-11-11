#!/usr/bin/env bash
# Binutils PASS1: out-of-the-box flags para linker/assembler de cross/bootstrap
set -Eeuo pipefail

: "${LC_ALL:=C}"; export LC_ALL
: "${TZ:=UTC}"; export TZ
: "${SOURCE_DATE_EPOCH:=1700000000}"; export SOURCE_DATE_EPOCH

# TARGET/PREFIX/SYSROOT são essenciais para pass1
: "${TARGET:=}"; : "${PREFIX:=}"; : "${SYSROOT:=}"
if [[ -z "${TARGET}" || -z "${PREFIX}" ]]; then
  echo "[binutils-pass1] AVISO: TARGET/PREFIX não definidos; usando modo host (não recomendado p/ bootstrap)." >&2
fi

# Opções seguras p/ pass1 (sem NLS, sem multilib, sem werror)
CONF=(
  ${TARGET:+--target="${TARGET}"}
  ${PREFIX:+--prefix="${PREFIX}"}
  ${SYSROOT:+--with-sysroot="${SYSROOT}"}
  --disable-nls
  --disable-multilib
  --disable-werror
)
export CONFIGURE_OPTS="${CONFIGURE_OPTS:-} ${CONF[*]}"

# Flags conservadoras (não forçar -fuse-ld, etc.)
: "${CFLAGS:= -O2 -pipe}"; export CFLAGS
: "${CXXFLAGS:= -O2 -pipe}"; export CXXFLAGS
: "${LDFLAGS:=}"; export LDFLAGS

# PATH priorizando o toolchain recém-instalado (se existir)
if [[ -n "${PREFIX}" && -d "${PREFIX}/bin" ]]; then
  export PATH="${PREFIX}/bin:${PATH}"
fi

echo "[binutils-pass1] CONFIGURE_OPTS=${CONFIGURE_OPTS}"
