#!/usr/bin/env bash
# LLDB final — validação e registro
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "lldb" "final" "$*" || echo "[lldb-final-post] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[lldb-final-post][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[lldb-final-post][WARN] $*"; }

: "${ROOT:?ROOT não definido}"

fails=0
if chroot "${ROOT}" /usr/bin/lldb --version >/dev/null 2>&1 || "${ROOT}/usr/bin/lldb" --version >/dev/null 2>&1; then
  :
else
  warn "lldb --version falhou"; fails=$((fails+1))
fi

# Verificar módulo Python (best-effort)
if [[ -x "${ROOT}/usr/bin/python3" ]]; then
  if chroot "${ROOT}" /usr/bin/python3 - <<'PY' >/dev/null 2>&1; then
import sys
import lldb
print(lldb.SBDebugger.Create())  # smoke test
PY
    :
  else
    warn "binding Python do LLDB indisponível (verifique SWIG/PYTHON path)"; fails=$((fails+1))
  fi
fi

state_dir="${ROOT}/usr/src/adm/state/final/lldb"
mkdir -p -- "$state_dir"
{
  echo "package=dev/lldb"
  echo "version=18.1.8"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "validate_failures=${fails}"
} > "${state_dir}/build.info"

ok "lldb validado"
