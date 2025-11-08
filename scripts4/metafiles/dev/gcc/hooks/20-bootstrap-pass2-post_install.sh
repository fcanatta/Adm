#!/usr/bin/env bash
# 20-bootstrap-pass2-post_install.sh
# Valida gcc/c++ no stage; registra estado.

set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "gcc-pass2" "bootstrap" "$*" || echo "[gcc-pass2-post] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[gcc-pass2-post][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[gcc-pass2-post][WARN] $*"; }

: "${ROOT:?ROOT não definido}"
: "${TARGET:?TARGET não definido}"

PREFIX="/tools"

validate(){
  local b="$1"
  if command -v chroot >/dev/null 2>&1 && [[ -d "${ROOT}/proc" && -d "${ROOT}/dev" ]]; then
    chroot "${ROOT}" "$b" --version >/dev/null 2>&1
  else
    "${ROOT}${b}" --version >/dev/null 2>&1
  fi
}

fails=0
for b in "/tools/bin/${TARGET}-gcc" "/tools/bin/${TARGET}-g++"; do
  validate "$b" || { warn "validação falhou: $b"; fails=$((fails+1)); }
done

state_dir="${ROOT}/usr/src/adm/state/bootstrap/stageX/gcc-pass2"
mkdir -p -- "$state_dir"
{
  echo "package=dev/gcc"
  echo "version=14.2.0"
  echo "mode=pass2"
  echo "prefix=${PREFIX}"
  echo "target=${TARGET}"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "validate_failures=${fails}"
} > "${state_dir}/build.info"

ok "gcc pass2 validado. Próximo passo: toolchain final ou libs adicionais."
