#!/usr/bin/env bash
# GCC FINAL — configuração enxuta e robusta para CRT real
set -Eeuo pipefail

: "${LC_ALL:=C}"; export LC_ALL
: "${TZ:=UTC}";   export TZ
: "${SOURCE_DATE_EPOCH:=1700000000}"; export SOURCE_DATE_EPOCH

: "${TARGET:=}";  : "${PREFIX:=/usr}"; : "${SYSROOT:=/}"

if [[ -z "${TARGET}" ]]; then
    echo "[gcc-final] ERRO: TARGET não definido (ex: x86_64-linux-musl)" >&2
    exit 2
fi

# Detecta MUSL vs GLIBC
LIBC_TYPE="glibc"
if [[ -f "${SYSROOT}/usr/include/unistd.h" ]]; then
    if grep -qi musl "${SYSROOT}/usr/include/unistd.h"; then
        LIBC_TYPE="musl"
    fi
fi

echo "[gcc-final] TARGET=${TARGET} SYSROOT=${SYSROOT} PREFIX=${PREFIX}"
echo "[gcc-final] libc detectada: ${LIBC_TYPE}"

# Flags base
export CFLAGS_FOR_TARGET="${CFLAGS_FOR_TARGET:--O2 -pipe}"
export CXXFLAGS_FOR_TARGET="${CXXFLAGS_FOR_TARGET:--O2 -pipe}"

# Profiling, sanitizers etc. habilitados
EXTRA_LANGS=c,c++

# Ajustes específicos
CONF=(
  --target="${TARGET}"
  --prefix="${PREFIX}"
  --with-sysroot="${SYSROOT}"
  --disable-multilib
  --enable-shared
  --enable-threads=posix
  --enable-languages=${EXTRA_LANGS}
  --enable-lto
  --enable-gold
  --enable-libgomp       # OpenMP
  --enable-libatomic
)

# Se GLIBC → habilitar extras
if [[ "${LIBC_TYPE}" == "glibc" ]]; then
    CONF+=(
      --enable-libquadmath
      --enable-libquadmath-support
      --enable-libsanitizer
      --enable-libitm
      --enable-libvtv
    )
else
    # Em MUSL → desabilitar libs problemáticas
    CONF+=(
      --disable-libquadmath
      --disable-libitm
      --disable-libvtv
      --disable-libsanitizer
    )
fi

export CONFIGURE_OPTS="${CONFIGURE_OPTS:-} ${CONF[*]}"

# Compilação completa
export MAKE_TARGETS="${MAKE_TARGETS:-all}"
export MAKE_INSTALL_TARGETS="${MAKE_INSTALL_TARGETS:-install}"

# PATH — prioriza binutils próprios
if [[ -d "${PREFIX}/bin" ]]; then
  export PATH="${PREFIX}/bin:${PATH}"
fi

echo "[gcc-final] CONFIGURE_OPTS=${CONFIGURE_OPTS}"
echo "[gcc-final] MAKE_TARGETS=${MAKE_TARGETS}"
echo "[gcc-final] MAKE_INSTALL_TARGETS=${MAKE_INSTALL_TARGETS}"
