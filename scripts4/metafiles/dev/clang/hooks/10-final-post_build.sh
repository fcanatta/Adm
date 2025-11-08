#!/usr/bin/env bash
# Clang final — build + install
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "clang" "final" "$*" || echo "[clang-final-build] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[clang-final-build][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[clang-final-build][WARN] $*"; }
err(){ command -v adm_err  >/dev/null 2>&1 && adm_err "$*"  || { echo "[clang-final-build][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

pushd "${BUILD_DIR}" >/dev/null
if [[ -f build.ninja ]]; then
  log "ninja -j${JOBS}"
  ninja -j"${JOBS}" > "${BUILD_DIR}/build.log" 2>&1 || err "ninja falhou"
else
  log "make -j${JOBS}"
  make -j"${JOBS}" > "${BUILD_DIR}/build.log" 2>&1 || err "make falhou"
fi

log "instalando em ${ROOT}/usr"
if command -v cmake >/dev/null 2>&1; then
  DESTDIR="${ROOT}" cmake --install . > "${BUILD_DIR}/install.log" 2>&1 || err "cmake --install falhou"
else
  make DESTDIR="${ROOT}" install > "${BUILD_DIR}/install.log" 2>&1 || err "make install falhou"
fi

# Symlinks usuais (cc/clang/clang++)
if [[ -x "${ROOT}/usr/bin/clang" && ! -e "${ROOT}/usr/bin/cc" ]]; then
  ln -sf clang "${ROOT}/usr/bin/cc" || true
fi
if [[ -x "${ROOT}/usr/bin/clang++" && ! -e "${ROOT}/usr/bin/c++" ]]; then
  ln -sf clang++ "${ROOT}/usr/bin/c++" || true
fi

ok "clang instalado em ${ROOT}/usr"
popd >/dev/null
