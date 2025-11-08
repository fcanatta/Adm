#!/usr/bin/env bash
# LLVM final — pré-build: configura CMake em modo Release para /usr
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "llvm" "final" "$*" || echo "[llvm-final-pre] $*"; }
ok(){ command -v adm_ok   >/dev/null 2>&1 && adm_ok "$*"   || echo "[llvm-final-pre][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[llvm-final-pre][WARN] $*"; }
err(){ command -v adm_err  >/dev/null 2>&1 && adm_err "$*"  || { echo "[llvm-final-pre][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}-build-final}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

PREFIX="/usr"
GEN="Unix Makefiles"
if command -v ninja >/dev/null 2>&1; then
  GEN="Ninja"
fi
mkdir -p -- "${BUILD_DIR}"

# Opções padrão
CMAKE_OPTS=(
  "-G" "${GEN}"
  "-DCMAKE_BUILD_TYPE=Release"
  "-DCMAKE_INSTALL_PREFIX=${PREFIX}"
  "-DLLVM_ENABLE_PROJECTS="              # somente core (sem clang/lld etc)
  "-DLLVM_ENABLE_RUNTIMES="
  "-DLLVM_ENABLE_ZLIB=ON"
  "-DLLVM_ENABLE_ZSTD=ON"
  "-DLLVM_ENABLE_TERMINFO=ON"
  "-DLLVM_TARGETS_TO_BUILD=all"          # ou ajuste p/ minimizar
  "-DLLVM_BUILD_LLVM_DYLIB=ON"
  "-DLLVM_LINK_LLVM_DYLIB=ON"
  "-DLLVM_ENABLE_ASSERTIONS=OFF"
)

# Opcional: ativar LTO no build do próprio LLVM (cuidado com RAM/tempo)
if [[ "${LLVM_ENABLE_LTO:-0}" == "1" ]]; then
  CMAKE_OPTS+=( "-DLLVM_ENABLE_LTO=Thin" )
fi

log "configurando CMake para LLVM (generator=${GEN})"
pushd "${BUILD_DIR}" >/dev/null
cmake "${CMAKE_OPTS[@]}" "${SRC_DIR}/llvm" > "${BUILD_DIR}/cmake.configure.log" 2>&1 \
  || err "cmake configure falhou (veja ${BUILD_DIR}/cmake.configure.log)"
ok "configure concluído"
popd >/dev/null
