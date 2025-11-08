#!/usr/bin/env bash
# Clang final — validação e registro
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "clang" "final" "$*" || echo "[clang-final-post] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[clang-final-post][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[clang-final-post][WARN] $*"; }

: "${ROOT:?ROOT não definido}"

fails=0
if chroot "${ROOT}" /usr/bin/clang --version >/dev/null 2>&1 || "${ROOT}/usr/bin/clang" --version >/dev/null 2>&1; then
  :
else
  warn "clang --version falhou"; fails=$((fails+1))
fi
if chroot "${ROOT}" /usr/bin/clang++ --version >/dev/null 2>&1 || "${ROOT}/usr/bin/clang++" --version >/dev/null 2>&1; then
  :
else
  warn "clang++ --version falhou"; fails=$((fails+1))
fi

state_dir="${ROOT}/usr/src/adm/state/final/clang"
mkdir -p -- "$state_dir"
{
  echo "package=dev/clang"
  echo "version=18.1.8"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "validate_failures=${fails}"
} > "${state_dir}/build.info"

ok "clang validado"
