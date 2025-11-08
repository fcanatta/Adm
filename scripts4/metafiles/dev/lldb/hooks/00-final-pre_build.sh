#!/usr/bin/env bash
# LLDB final — pré-build: CMake com LLVM_ENABLE_PROJECTS=lldb;clang
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "lldb" "final" "$*" || echo "[lldb-final-pre] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[lldb-final-pre][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[lldb-final-pre][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[lldb-final-pre][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"      # monorepo llvm-project
: "${BUILD_DIR:=${SRC_DIR%/}-build-lldb}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

PREFIX="/usr"
GEN="Unix Makefiles"; command -v ninja >/dev/null 2>&1 && GEN="Ninja"
mkdir -p -- "${BUILD_DIR}"

# Garantir que LLVM/Clang instalados sejam visíveis
export PKG_CONFIG_PATH="${ROOT}/usr/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${ROOT}/usr/lib:${LD_LIBRARY_PATH:-}"
export PATH="${ROOT}/usr/bin:${PATH}"

# Localização do Python
PY_BIN="${PY_BIN:-${ROOT}/usr/bin/python3}"
[[ -x "${PY_BIN}" ]] || PY_BIN="$(command -v python3 2>/dev/null || true)"
[[ -x "${PY_BIN}" ]] || warn "python3 não encontrado; prosseguindo (cmake pode falhar)"

PROJECTS="lldb;clang"
TARGETS="${LLVM_TARGETS:-all}"

CMAKE_OPTS=(
  "-G" "${GEN}"
  "-DCMAKE_BUILD_TYPE=Release"
  "-DCMAKE_INSTALL_PREFIX=${PREFIX}"
  "-DLLVM_ENABLE_PROJECTS=${PROJECTS}"
  "-DLLVM_TARGETS_TO_BUILD=${TARGETS}"
  "-DLLVM_BUILD_LLVM_DYLIB=ON"
  "-DLLVM_LINK_LLVM_DYLIB=ON"
  "-DLLVM_ENABLE_ZLIB=ON"
  "-DLLVM_ENABLE_ZSTD=ON"
  "-DLLVM_ENABLE_TERMINFO=ON"

  "-DLLDB_ENABLE_PYTHON=ON"
  "-DPYTHON_EXECUTABLE=${PY_BIN}"
  "-DLLDB_ENABLE_LIBEDIT=ON"
  "-DLLDB_ENABLE_CURSES=ON"
)

# SWIG (bindings)
if command -v swig >/dev/null 2>&1; then
  : # ok — cmake detecta sozinho
else
  warn "SWIG não encontrado; bindings Python do LLDB podem não ser gerados"
fi

log "configurando CMake para LLDB (generator=${GEN})"
pushd "${BUILD_DIR}" >/dev/null
cmake "${CMAKE_OPTS[@]}" "${SRC_DIR}/llvm" > "${BUILD_DIR}/cmake.configure.log" 2>&1 \
  || err "cmake configure falhou (veja ${BUILD_DIR}/cmake.configure.log)"
ok "configure concluído"
popd >/dev/null
