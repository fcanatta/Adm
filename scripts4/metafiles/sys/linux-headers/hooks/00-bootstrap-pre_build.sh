#!/usr/bin/env bash
# Instala headers do Linux no rootfs do stage do bootstrap

set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "linux-headers" "bootstrap" "$*" || echo "[linux-headers-pre] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[linux-headers-pre][OK] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[linux-headers-pre][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
BUILD_DIR="${SRC_DIR%/}-build"

log "Preparando diretório de build"
mkdir -p -- "${BUILD_DIR}"

ok "Pré-build concluído"
