#!/usr/bin/env bash
# 10-bootstrap-pass2-post_build.sh
# Compila all, instala gcc e libstdc++ no ROOT (/tools), linkando para libc do stage.

set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "gcc-pass2" "bootstrap" "$*" || echo "[gcc-pass2-build] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[gcc-pass2-build][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[gcc-pass2-build][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[gcc-pass2-build][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}-build-pass2}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

PREFIX="/tools"

pushd "${BUILD_DIR}" >/dev/null
log "make (JOBS=${JOBS})"
make -j"${JOBS}" > "${BUILD_DIR}/make.pass2.log" 2>&1 || { err "falha em make pass2; veja logs"; }

log "make DESTDIR=${ROOT} install"
set +e
make DESTDIR="${ROOT}" install > "${BUILD_DIR}/install.pass2.log" 2>&1
rc=$?; set -e
if [[ $rc -ne 0 ]]; then
  warn "install com DESTDIR falhou; tentando sem DESTDIR (pode instalar no host!)"
  make install >> "${BUILD_DIR}/install.pass2.log" 2>&1 || err "install falhou"
  warn "movendo conteúdo de ${PREFIX} para ${ROOT}${PREFIX} (best-effort)"
  for d in bin lib lib64 libexec include share; do
    [[ -d "${PREFIX}/${d}" ]] && { mkdir -p -- "${ROOT}${PREFIX}/${d}"; cp -a "${PREFIX}/${d}/." "${ROOT}${PREFIX}/${d}/" || true; }
  done
fi

# Libstdc++ (algumas árvores requerem etapa explícita)
if [[ -d "${BUILD_DIR}/x86_64-"*"/libstdc++-v3" || -d "${SRC_DIR}/libstdc++-v3" ]]; then
  log "garantindo instalação de libstdc++ (separada)"
  make -C "${BUILD_DIR}" DESTDIR="${ROOT}" install-target-libstdc++-v3 >> "${BUILD_DIR}/install.pass2.log" 2>&1 || true
fi

ok "GCC pass2 instalado em ${ROOT}${PREFIX}"
popd >/dev/null
