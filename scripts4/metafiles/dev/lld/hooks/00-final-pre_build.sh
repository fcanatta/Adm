#!/usr/bin/env bash
# LLD final — pré-build: CMake com LLVM_ENABLE_PROJECTS=lld
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "lld" "final" "$*" || echo "[lld-final-pre] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[lld-final-pre][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[lld-final-pre][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[lld-final-pre][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"      # raiz do monorepo llvm-project
: "${BUILD_DIR:=${SRC_DIR%/}-build-lld}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

PREFIX="/usr"
GEN="Unix Makefiles"; command -v ninja >/dev/null 2>&1 && GEN="Ninja"
mkdir -p -- "${BUILD_DIR}"

# Garantir que o LLVM já instalado no ROOT seja encontrado
export PKG_CONFIG_PATH="${ROOT}/usr/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${ROOT}/usr/lib:${LD_LIBRARY_PATH:-}"
export PATH="${ROOT}/usr/bin:${PATH}"

TARGETS="${LLVM_TARGETS:-all}"

CMAKE_OPTS=(
  "-G" "${GEN}"
  "-DCMAKE_BUILD_TYPE=Release"
  "-DCMAKE_INSTALL_PREFIX=${PREFIX}"
  "-DLLVM_ENABLE_PROJECTS=lld"
  "-DLLVM_ENABLE_RUNTIMES="
  "-DLLVM_TARGETS_TO_BUILD=${TARGETS}"
  "-DLLVM_BUILD_LLVM_DYLIB=ON"
  "-DLLVM_LINK_LLVM_DYLIB=ON"
  "-DLLVM_ENABLE_ZLIB=ON"
  "-DLLVM_ENABLE_ZSTD=ON"
  "-DLLVM_ENABLE_TERMINFO=ON"
)

pushd "${BUILD_DIR}" >/dev/null
cmake "${CMAKE_OPTS[@]}" "${SRC_DIR}/llvm" > "${BUILD_DIR}/cmake.configure.log" 2>&1 \
  || err "cmake configure falhou (veja ${BUILD_DIR}/cmake.configure.log)"
ok "configure concluído"
popd >/dev/null
