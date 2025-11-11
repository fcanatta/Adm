#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

: "${PREFIX:=/usr}"
: "${SYSROOT:=/}"

# Build dir
: "${LLVM_BUILD:=build}"
mkdir -p "${LLVM_BUILD}"

CMAKE_OPTS=(
  -DCMAKE_INSTALL_PREFIX="${PREFIX}"
  -DCMAKE_BUILD_TYPE=Release
  -DLLVM_ENABLE_PROJECTS="clang;lld;compiler-rt"
  -DLLVM_TARGETS_TO_BUILD="X86;ARM;AArch64;RISCV"
  -DLLVM_ENABLE_LTO=OFF
  -DLLVM_ENABLE_RTTI=ON
  -DLLVM_ENABLE_EH=ON
)

# profile aggressive
if [[ "${ADM_PROFILE:-}" == "aggressive" ]]; then
  export CFLAGS="${CFLAGS:-} -O3 -march=native -mtune=native -pipe"
  export CXXFLAGS="${CXXFLAGS:-} -O3 -march=native -mtune=native -pipe"
  CMAKE_OPTS+=(
    -DLLVM_ENABLE_LTO=ON
  )
fi

export CONFIGURE_OPTS="${CMAKE_OPTS[*]}"
export MAKE_TARGETS="clang lld"
export MAKE_INSTALL_TARGETS="install"

echo "[LLVM] CONFIGURE_OPTS=${CONFIGURE_OPTS}"
