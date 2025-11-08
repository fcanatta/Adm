#!/usr/bin/env bash
# Binutils final: build + install
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "binutils" "final" "$*" || echo "[binutils-final-build] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[binutils-final-build][OK] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[binutils-final-build][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}-build-final}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

pushd "${BUILD_DIR}" >/dev/null
make -j"${JOBS}" > "${BUILD_DIR}/make.log" 2>&1 || err "make falhou"
make DESTDIR="${ROOT}" install > "${BUILD_DIR}/install.log" 2>&1 || err "install falhou"
ok "binutils instalado em ${ROOT}/usr"
popd >/dev/null
