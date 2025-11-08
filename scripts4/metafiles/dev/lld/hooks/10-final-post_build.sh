#!/usr/bin/env bash
# LLD final — build + install
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "lld" "final" "$*" || echo "[lld-final-build] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[lld-final-build][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[lld-final-build][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[lld-final-build][ERR] $*" >&2; exit 1; } }

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

# Symlink opcional: ld -> ld.lld (deixe desativado por padrão)
if [[ "${LLD_DEFAULT_LD:-0}" == "1" ]]; then
  mkdir -p -- "${ROOT}/usr/bin"
  ln -sf ld.lld "${ROOT}/usr/bin/ld" || warn "não foi possível criar symlink ld → ld.lld"
fi

ok "lld instalado em ${ROOT}/usr"
popd >/dev/null
