#!/usr/bin/env bash
# GNU make — build + install (DESTDIR), com testes opcionais

set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "make" "final" "$*" || echo "[make-build] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[make-build][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[make-build][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[make-build][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

pushd "${BUILD_DIR}" >/dev/null

log "make -j${JOBS}"
make -j"${JOBS}" > "${BUILD_DIR}/make.log" 2>&1 || err "make falhou (veja ${BUILD_DIR}/make.log)"

# Testes (opcionais; em alguns ambientes de bootstrap podem falhar por falta de locale/tools)
if [[ "${MAKE_RUN_TESTS:-0}" == "1" ]]; then
  log "rodando test-suite (opcional)"
  if make -j"${JOBS}" check > "${BUILD_DIR}/make.check.log" 2>&1; then
    ok "testes OK"
  else
    warn "testes falharam — veja ${BUILD_DIR}/make.check.log (prosseguindo)"
  fi
fi

log "make DESTDIR='${ROOT}' install"
make DESTDIR="${ROOT}" install > "${BUILD_DIR}/install.log" 2>&1 || err "install falhou (veja ${BUILD_DIR}/install.log)"

# Symlink 'gmake' (útil para compat em alguns ecossistemas *BSD/Illumos/etc.)
mkdir -p -- "${ROOT}/usr/bin"
ln -sf make "${ROOT}/usr/bin/gmake" || true

ok "GNU make instalado em ${ROOT}/usr"
popd >/dev/null
