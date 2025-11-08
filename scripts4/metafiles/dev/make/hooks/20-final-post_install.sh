#!/usr/bin/env bash
# GNU make — pós-instalação: validação e registro

set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "make" "final" "$*" || echo "[make-post] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[make-post][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[make-post][WARN] $*"; }

: "${ROOT:?ROOT não definido}"

fails=0
if chroot "${ROOT}" /usr/bin/make --version >/dev/null 2>&1 || "${ROOT}/usr/bin/make" --version >/dev/null 2>&1; then
  :
else
  warn "validação falhou: make --version"; fails=$((fails+1))
fi

state_dir="${ROOT}/usr/src/adm/state/final/make"
mkdir -p -- "${state_dir}"
{
  echo "package=dev/make"
  echo "version=4.4.1"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "validate_failures=${fails}"
} > "${state_dir}/build.info"

ok "pós-instalação concluída"
