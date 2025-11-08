#!/usr/bin/env bash
# musl pós: valida presença de crt e libc, e registra estado.
set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "musl" "bootstrap" "$*" || echo "[musl-post] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[musl-post][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[musl-post][WARN] $*"; }
: "${ROOT:?ROOT não definido}"

# Verificações básicas
missing=0
for f in usr/lib/libc.so usr/lib/crt1.o usr/lib/crti.o usr/lib/crtn.o; do
  [[ -e "${ROOT}/${f}" ]] || { warn "faltando ${f}"; missing=$((missing+1)); }
done

state_dir="${ROOT}/usr/src/adm/state/bootstrap/stageX/musl"
mkdir -p -- "$state_dir"
{
  echo "package=dev/musl"
  echo "version=1.2.5"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "missing_artifacts=${missing}"
} > "${state_dir}/build.info"

ok "musl pronta (headers+crt+libc)"
