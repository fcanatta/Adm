#!/usr/bin/env bash
# musl bootstrap pre_build: instala em /usr do stage (não /tools).
set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "musl" "bootstrap" "$*" || echo "[musl-pre] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[musl-pre][OK] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[musl-pre][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}-build}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"
TARGET="${BOOTSTRAP_TARGET:-${TARGET:-}}"; [[ -n "${TARGET}" ]] || err "TARGET não definido"

PREFIX="/usr"
mkdir -p -- "${BUILD_DIR}"

# musl usa configure próprio (não autoconf): ./configure --prefix=/usr --target=$TARGET
pushd "${BUILD_DIR}" >/dev/null
../configure --prefix="${PREFIX}" --target="${TARGET}" > "${BUILD_DIR}/configure.log" 2>&1
ok "configure concluído"
popd >/dev/null
