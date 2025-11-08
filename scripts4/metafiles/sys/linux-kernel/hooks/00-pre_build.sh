#!/usr/bin/env bash
# Kernel: pré-build — escolhe .config e prepara árvore
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "linux-kernel" "final" "$*" || echo "[kernel-pre] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[kernel-pre][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[kernel-pre][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[kernel-pre][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

cd "${SRC_DIR}"

# Escolha de configuração:
# 1) Se houver config fornecido junto dos hooks (config), usa-o.
# 2) Caso contrário, usa 'defconfig'.
CFG_FROM_HOOK="$(dirname "$0")/config"
if [[ -r "${CFG_FROM_HOOK}" ]]; then
  log "usando .config fornecido em hooks"
  cp -f -- "${CFG_FROM_HOOK}" .config
else
  log "gerando defconfig"
  make mrproper >/dev/null 2>&1 || true
  make defconfig > "${SRC_DIR}/defconfig.log" 2>&1
fi

# Opcional: refinar via localmodconfig (se estiver rodando no host com HW)
if [[ "${KCFG_LOCALMOD:-0}" == "1" ]]; then
  log "ajustando com localmodconfig"
  make localmodconfig > "${SRC_DIR}/localmodconfig.log" 2>&1 || warn "localmodconfig falhou (prosseguindo)"
fi

ok "pré-build pronto"
