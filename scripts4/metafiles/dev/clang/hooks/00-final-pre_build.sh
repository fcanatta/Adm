#!/usr/bin/env bash
# Clang final — pré-build: configura CMake com LLVM_ENABLE_PROJECTS=clang;clang-tools-extra
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "clang" "final" "$*" || echo "[clang-final-pre] $*"; }
ok(){ command -v adm_ok   >/dev/null 2>&1 && adm_ok "$*"   || echo "[clang-final-pre][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[clang-final-pre][WARN] $*"; }
err(){ command -v adm_err  >/dev/null 2>&1 && adm_err "$*"  || { echo "[clang-final-pre][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"      # raiz do monorepo
: "${BUILD_DIR:=${SRC_DIR%/}-build-clang}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

PREFIX="/usr"
GEN="Unix Makefiles"
if command -v ninja >/dev/null 2>&1; then
  GEN="Ninja"
fi
mkdir -p -- "${BUILD_DIR}"

# Se LLVM já foi instalado no ROOT, garantir que include/lib/path sejam encontrados
export PKG_CONFIG_PATH="${ROOT}/usr/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${ROOT}/usr/lib:${LD_LIBRARY_PATH:-}"
export PATH="${ROOT}/usr/bin:${PATH}"

PROJECTS="clang;clang-tools-extra"
# Opcional: adicionar lld/lldb se desejar (e tiver deps): PROJECTS="clang;clang-tools-extra;lld"

CMAKE_OPTS=(
  "-G" "${GEN}"
  "-DCMAKE_BUILD_TYPE=Release"
  "-DCMAKE_INSTALL_PREFIX=${PREFIX}"
  "-DLLVM_ENABLE_PROJECTS=${PROJECTS}"
  "-DLLVM_ENABLE_RUNTIMES="
  "-DLLVM_ENABLE_ZLIB=ON"
  "-DLLVM_ENABLE_ZSTD=ON"
  "-DLLVM_ENABLE_TERMINFO=ON"
  "-DLLVM_BUILD_LLVM_DYLIB=ON"
  "-DLLVM_LINK_LLVM_DYLIB=ON"
  "-DCLANG_VENDOR=ADM"
)

# Caso musl: desativar unwinder do libunwind próprio (ajuste conforme ambiente)
if [[ "${CLANG_WITH_LIBUNWIND:-0}" == "1" ]]; then
  CMAKE_OPTS+=( "-DLIBUNWIND_ENABLE_SHARED=ON" )
fi

log "configurando CMake para Clang (generator=${GEN})"
pushd "${BUILD_DIR}" >/dev/null
cmake "${CMAKE_OPTS[@]}" "${SRC_DIR}/llvm" > "${BUILD_DIR}/cmake.configure.log" 2>&1 \
  || err "cmake configure falhou (veja ${BUILD_DIR}/cmake.configure.log)"
ok "configure concluído"
popd >/dev/null
