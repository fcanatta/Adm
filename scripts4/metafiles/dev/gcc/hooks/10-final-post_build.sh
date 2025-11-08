#!/usr/bin/env bash
# GCC final: build + install
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "gcc" "final" "$*" || echo "[gcc-final-build] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[gcc-final-build][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[gcc-final-build][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[gcc-final-build][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}-build-final}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

pushd "${BUILD_DIR}" >/dev/null
log "make (JOBS=${JOBS})"
make -j"${JOBS}" > "${BUILD_DIR}/make.log" 2>&1 || err "make falhou"

log "make DESTDIR=${ROOT} install"
make DESTDIR="${ROOT}" install > "${BUILD_DIR}/install.log" 2>&1 || err "install falhou"

# Opcional: mover cc -> gcc symlink
if [[ -x "${ROOT}/usr/bin/gcc" && ! -e "${ROOT}/usr/bin/cc" ]]; then
  ln -sf gcc "${ROOT}/usr/bin/cc" || true
fi

ok "gcc final instalado em ${ROOT}/usr"
popd >/dev/null
