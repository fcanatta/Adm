#!/usr/bin/env bash
# musl bootstrap build/install
set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "musl" "bootstrap" "$*" || echo "[musl-build] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[musl-build][OK] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[musl-build][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}-build}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

pushd "${BUILD_DIR}" >/dev/null
make -j"${JOBS}" > "${BUILD_DIR}/make.log" 2>&1 || { err "falha no make; veja logs"; }
make DESTDIR="${ROOT}" install > "${BUILD_DIR}/install.log" 2>&1 || { err "falha no install; veja logs"; }
ok "musl instalada em ${ROOT}/usr"
popd >/dev/null
