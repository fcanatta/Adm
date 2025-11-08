#!/usr/bin/env bash
# Python3 final — build + install
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "python3" "final" "$*" || echo "[python3-build] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[python3-build][OK] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[python3-build][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

cd "${BUILD_DIR}"

log "make -j${JOBS}"
make -j"${JOBS}" > "${BUILD_DIR}/make.log" 2>&1 || err "make falhou"

log "make DESTDIR=${ROOT} install"
make DESTDIR="${ROOT}" install > "${BUILD_DIR}/install.log" 2>&1 || err "install falhou"

# Bytecode para performance (não crítico, mas útil)
if command -v "${ROOT}/usr/bin/python3" >/dev/null 2>&1; then
  "${ROOT}/usr/bin/python3" -m compileall -q "${ROOT}/usr/lib/python3."* || true
fi

# Symlinks usuais
mkdir -p -- "${ROOT}/usr/bin"
[[ -x "${ROOT}/usr/bin/python3" ]] || ln -sf "python3.13" "${ROOT}/usr/bin/python3" 2>/dev/null || true
[[ -x "${ROOT}/usr/bin/pip3" ]]    || { [[ -x "${ROOT}/usr/bin/pip3.13" ]] && ln -sf "pip3.13" "${ROOT}/usr/bin/pip3" || true; }

ok "python3 instalado em ${ROOT}/usr"
