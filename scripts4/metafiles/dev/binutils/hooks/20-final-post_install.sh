#!/usr/bin/env bash
# Binutils final: validação e registro
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "binutils" "final" "$*" || echo "[binutils-final-post] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[binutils-final-post][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[binutils-final-post][WARN] $*"; }

: "${ROOT:?ROOT não definido}"

fails=0
for b in /usr/bin/ld /usr/bin/as /usr/bin/ar /usr/bin/ranlib /usr/bin/strings; do
  if chroot "${ROOT}" "$b" --version >/dev/null 2>&1 || "${ROOT}${b}" --version >/dev/null 2>&1; then
    :
  else
    warn "validação falhou: $b"; fails=$((fails+1))
  fi
done

state_dir="${ROOT}/usr/src/adm/state/final/binutils"
mkdir -p -- "$state_dir"
{
  echo "package=dev/binutils"
  echo "version=2.45"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "validate_failures=${fails}"
} > "${state_dir}/build.info"

ok "pós binutils final concluído"
