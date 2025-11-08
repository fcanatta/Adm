#!/usr/bin/env bash
# LLD final — validação e registro
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "lld" "final" "$*" || echo "[lld-final-post] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[lld-final-post][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[lld-final-post][WARN] $*"; }

: "${ROOT:?ROOT não definido}"

fails=0
if chroot "${ROOT}" /usr/bin/ld.lld --version >/dev/null 2>&1 || "${ROOT}/usr/bin/ld.lld" --version >/dev/null 2>&1; then
  :
else
  warn "ld.lld --version falhou"; fails=$((fails+1))
fi
# lld-link (modo MSVC/COFF) pode não ser construído em todos os targets
if [[ -x "${ROOT}/usr/bin/lld-link" ]] || chroot "${ROOT}" /usr/bin/lld-link --version >/dev/null 2>&1; then
  : # ok (se existir)
fi

state_dir="${ROOT}/usr/src/adm/state/final/lld"
mkdir -p -- "$state_dir"
{
  echo "package=dev/lld"
  echo "version=18.1.8"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "validate_failures=${fails}"
} > "${state_dir}/build.info"

ok "lld validado"
