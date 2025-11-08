#!/usr/bin/env bash
# 10-bootstrap-stage0-post_build.sh
# Hook de build/instalação para GCC pass1:
# - Constrói 'all-gcc' e 'all-target-libgcc'
# - Instala em ${ROOT}/tools (com DESTDIR)

set -euo pipefail

log()  { command -v adm_step >/dev/null 2>&1 && adm_step "gcc-pass1" "stage0" "$* " || echo "[gcc-pass1-build] $*"; }
ok()   { command -v adm_ok   >/dev/null 2>&1 && adm_ok "$*"   || echo "[gcc-pass1-build][OK] $*"; }
warn() { command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[gcc-pass1-build][WARN] $*"; }
err()  { command -v adm_err  >/dev/null 2>&1 && adm_err "$*"  || { echo "[gcc-pass1-build][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido (rootfs do stage0)}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}-build}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

PREFIX="/tools"

pushd "${BUILD_DIR}" >/dev/null

log "make all-gcc  (JOBS=${JOBS})"
make -j"${JOBS}" all-gcc >"${BUILD_DIR}/make.all-gcc.log" 2>&1 || { err "falha em all-gcc (veja ${BUILD_DIR}/make.all-gcc.log)"; }
ok "all-gcc concluído"

log "make all-target-libgcc"
make -j"${JOBS}" all-target-libgcc >"${BUILD_DIR}/make.all-target-libgcc.log" 2>&1 || { err "falha em all-target-libgcc (veja ${BUILD_DIR}/make.all-target-libgcc.log)"; }
ok "all-target-libgcc concluído"

log "make DESTDIR=${ROOT} install-gcc"
set +e
make DESTDIR="${ROOT}" install-gcc >"${BUILD_DIR}/make.install-gcc.log" 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  warn "install-gcc com DESTDIR falhou; tentando sem DESTDIR (ATENÇÃO: pode instalar fora do stage!)"
  make install-gcc >>"${BUILD_DIR}/make.install-gcc.log" 2>&1 || { err "install-gcc falhou; veja ${BUILD_DIR}/make.install-gcc.log"; }
  warn "gcc pode ter sido instalado no host; movendo para ${ROOT}${PREFIX} (melhor esforço)"
  # tentativa de recolher binários e libs para dentro do ROOT
  for d in bin lib libexec include; do
    [[ -d "${PREFIX}/${d}" ]] && mkdir -p -- "${ROOT}${PREFIX}/${d}" && cp -a "${PREFIX}/${d}/." "${ROOT}${PREFIX}/${d}/" 2>/dev/null || true
  done
fi

log "make DESTDIR=${ROOT} install-target-libgcc"
set +e
make DESTDIR="${ROOT}" install-target-libgcc >"${BUILD_DIR}/make.install-target-libgcc.log" 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  warn "install-target-libgcc com DESTDIR falhou; tentando sem DESTDIR (ATENÇÃO: pode instalar fora do stage!)"
  make install-target-libgcc >>"${BUILD_DIR}/make.install-target-libgcc.log" 2>&1 || { err "install-target-libgcc falhou; veja ${BUILD_DIR}/make.install-target-libgcc.log"; }
  warn "libgcc pode ter sido instalada no host; movendo para ${ROOT}${PREFIX} (melhor esforço)"
  for d in lib lib64; do
    [[ -d "${PREFIX}/${d}" ]] && mkdir -p -- "${ROOT}${PREFIX}/${d}" && cp -a "${PREFIX}/${d}/." "${ROOT}${PREFIX}/${d}/" 2>/dev/null || true
  done
fi

# Ajustes pós-instalação (best-effort)
# Alguns setups exigem symlinks do TARGET-gcc → gcc e vice-versa dentro do /tools.
if [[ -x "${ROOT}${PREFIX}/bin/${TARGET}-gcc" && ! -e "${ROOT}${PREFIX}/bin/gcc" ]]; then
  ln -sf "${TARGET}-gcc" "${ROOT}${PREFIX}/bin/gcc" || true
fi

ok "instalação do gcc pass1 concluída em ${ROOT}${PREFIX}"
popd >/dev/null
