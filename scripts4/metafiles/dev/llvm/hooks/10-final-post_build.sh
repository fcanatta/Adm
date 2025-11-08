#!/usr/bin/env bash
# LLVM final — build + install (CMake)
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "llvm" "final" "$*" || echo "[llvm-final-build] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[llvm-final-build][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[llvm-final-build][WARN] $*"; }
err(){ command -v adm_err  >/dev/null 2>&1 && adm_err "$*"  || { echo "[llvm-final-build][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

pushd "${BUILD_DIR}" >/dev/null

# Compilar
if [[ -f build.ninja ]]; then
  log "ninja -j${JOBS}"
  ninja -j"${JOBS}" > "${BUILD_DIR}/build.log" 2>&1 || err "ninja falhou"
else
  log "make -j${JOBS}"
  make -j"${JOBS}" > "${BUILD_DIR}/build.log" 2>&1 || err "make falhou"
fi

# Instalar (DESTDIR)
log "instalando em ${ROOT}/usr"
if command -v cmake >/dev/null 2>&1; then
  DESTDIR="${ROOT}" cmake --install . > "${BUILD_DIR}/install.log" 2>&1 || err "cmake --install falhou"
else
  make DESTDIR="${ROOT}" install > "${BUILD_DIR}/install.log" 2>&1 || err "make install falhou"
fi

ok "llvm instalado em ${ROOT}/usr"
popd >/dev/null
