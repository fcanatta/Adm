#!/usr/bin/env bash
# Validação + registro

set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "linux-headers" "bootstrap" "$*" || echo "[linux-headers-post] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[linux-headers-post][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[linux-headers-post][WARN] $*"; }

: "${ROOT:?ROOT não definido}"

missing=0
[[ -d "${ROOT}/usr/include" ]] || { warn "usr/include não encontrado"; missing=$((missing+1)); }
[[ -f "${ROOT}/usr/include/linux/version.h" ]] || { warn "version.h ausente"; missing=$((missing+1)); }

state_dir="${ROOT}/usr/src/adm/state/bootstrap/linux-headers"
mkdir -p -- "${state_dir}"

{
  echo "package=sys/linux-headers"
  echo "version=6.10.6"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "missing=${missing}"
} > "${state_dir}/build.info"

ok "Linux headers prontos"
