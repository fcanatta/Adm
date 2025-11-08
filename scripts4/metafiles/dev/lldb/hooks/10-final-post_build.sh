#!/usr/bin/env bash
# LLDB final — build + install
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "lldb" "final" "$*" || echo "[lldb-final-build] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[lldb-final-build][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[lldb-final-build][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[lldb-final-build][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

pushd "${BUILD_DIR}" >/dev/null
if [[ -f build.ninja ]]; then
  ninja -j"${JOBS}" > "${BUILD_DIR}/build.log" 2>&1 || err "ninja falhou"
else
  make -j"${JOBS}"  > "${BUILD_DIR}/build.log" 2>&1 || err "make falhou"
fi

if command -v cmake >/dev/null 2>&1; then
  DESTDIR="${ROOT}" cmake --install . > "${BUILD_DIR}/install.log" 2>&1 || err "cmake --install falhou"
else
  make DESTDIR="${ROOT}" install > "${BUILD_DIR}/install.log" 2>&1 || err "make install falhou"
fi

ok "lldb instalado em ${ROOT}/usr"
popd >/dev/null
