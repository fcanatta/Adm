#!/usr/bin/env bash
# Python3 final — pós-instalação (validações e registro)
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "python3" "final" "$*" || echo "[python3-post] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[python3-post][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[python3-post][WARN] $*"; }

: "${ROOT:?ROOT não definido}"

fails=0
pybin="${ROOT}/usr/bin/python3"
pipbin="${ROOT}/usr/bin/pip3"

# ensurepip (alguns setups só preparam; reforçar)
if [[ -x "${pybin}" ]]; then
  "${pybin}" -m ensurepip --upgrade >/dev/null 2>&1 || warn "ensurepip falhou"
else
  warn "python3 não encontrado em ${pybin}"; fails=$((fails+1))
fi

# Testes de runtime essenciais
if [[ -x "${pybin}" ]]; then
  "${pybin}" - <<'PY' >/dev/null 2>&1 || { warn "teste ssl/sqlite falhou"; fails=$((fails+1)); }
import ssl, sqlite3, sys
assert ssl.OPENSSL_VERSION
assert sqlite3.sqlite_version
PY
fi

# CA bundle: se sistema não tiver, tentar apontar certifi (opcional)
if [[ -x "${pybin}" ]]; then
  if ! "${pybin}" - <<'PY' >/dev/null 2>&1; then
import ssl, certifi, os
caf = certifi.where()
print(caf)
PY
    then
    : # certifi ausente — normal; deixe o sistema/proxy cuidar dos CAs
  fi
fi

# Registro
state_dir="${ROOT}/usr/src/adm/state/final/python3"
mkdir -p -- "$state_dir"
{
  echo "package=dev/python3"
  echo "version=3.13.9"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "validate_failures=${fails}"
} > "${state_dir}/build.info"

ok "python3 validado"
