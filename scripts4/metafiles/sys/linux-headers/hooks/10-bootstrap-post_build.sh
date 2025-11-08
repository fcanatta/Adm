#!/usr/bin/env bash
# Build/Install Linux API Headers

set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "linux-headers" "bootstrap" "$*" || echo "[linux-headers-build] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[linux-headers-build][OK] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[linux-headers-build][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"

pushd "${SRC_DIR}" >/dev/null

log "Fixando arquivos com make headers_install"
# Faz limpeza e instala os headers em usr/include
make mrproper      >/dev/null 2>&1 || true
make headers >/dev/null 2>&1 || true
make INSTALL_HDR_PATH="${ROOT}/usr" headers_install >/dev/null

ok "Headers instalados em ${ROOT}/usr/include"

popd >/dev/null
