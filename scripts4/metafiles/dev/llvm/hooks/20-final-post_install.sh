#!/usr/bin/env bash
# LLVM final — validação e registro
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "llvm" "final" "$*" || echo "[llvm-final-post] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[llvm-final-post][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[llvm-final-post][WARN] $*"; }

: "${ROOT:?ROOT não definido}"

fails=0
if chroot "${ROOT}" /usr/bin/llvm-config --version >/dev/null 2>&1 || "${ROOT}/usr/bin/llvm-config" --version >/dev/null 2>&1; then
  :
else
  warn "llvm-config --version falhou"; fails=$((fails+1))
fi

state_dir="${ROOT}/usr/src/adm/state/final/llvm"
mkdir -p -- "$state_dir"
{
  echo "package=dev/llvm"
  echo "version=18.1.8"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "validate_failures=${fails}"
} > "${state_dir}/build.info"

ok "llvm validado"
