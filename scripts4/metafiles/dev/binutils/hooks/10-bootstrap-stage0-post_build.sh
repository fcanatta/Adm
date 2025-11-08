#!/usr/bin/env bash
# 10-bootstrap-stage0-post_build.sh
# Hook de build/instalação do binutils para bootstrap stage0

set -euo pipefail

log()  { command -v adm_step >/dev/null 2>&1 && adm_step "binutils" "stage0" "$* " || echo "[stage0-build] $*"; }
ok()   { command -v adm_ok   >/dev/null 2>&1 && adm_ok "$*"   || echo "[stage0-build][OK] $*"; }
warn() { command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[stage0-build][WARN] $*"; }
err()  { command -v adm_err  >/dev/null 2>&1 && adm_err "$*"  || { echo "[stage0-build][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido (rootfs do stage0)}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}-build}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

PREFIX="/tools"

log "compilando binutils (JOBS=${JOBS})"
pushd "${BUILD_DIR}" >/dev/null
make -j"${JOBS}" >"${BUILD_DIR}/make.log" 2>&1 || { err "falha no make (veja ${BUILD_DIR}/make.log)"; }
ok "compilação concluída"

# Instalação no rootfs do stage (DESTDIR)
log "instalando em ${ROOT}${PREFIX}"
make DESTDIR="${ROOT}" install >"${BUILD_DIR}/install.log" 2>&1 || { err "falha no make install (veja ${BUILD_DIR}/install.log)"; }

# Opcional: strip para reduzir tamanho
if command -v strip >/dev/null 2>&1; then
  find "${ROOT}${PREFIX}/bin" -type f -perm -111 -exec strip --strip-unneeded {} + 2>/dev/null || true
fi

ok "post_build concluído (artefatos em ${ROOT}${PREFIX})"
popd >/dev/null
