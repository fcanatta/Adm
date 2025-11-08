#!/usr/bin/env bash
# Kernel: build do kernel + módulos e instalação no ROOT
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "linux-kernel" "final" "$*" || echo "[kernel-build] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[kernel-build][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[kernel-build][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[kernel-build][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

cd "${SRC_DIR}"

# Build kernel e módulos
log "compilando kernel (JOBS=${JOBS})"
make -j"${JOBS}" > "${SRC_DIR}/make.kernel.log" 2>&1 || err "falha no kernel (veja logs)"

log "compilando módulos"
make -j"${JOBS}" modules > "${SRC_DIR}/make.modules.log" 2>&1 || err "falha em modules (veja logs)"

# Detecta versão kernelrelease
KVER="$(make -s kernelrelease 2>/dev/null || true)"
[[ -n "${KVER}" ]] || err "não foi possível determinar kernelrelease"

# Instala módulos em ${ROOT}
log "instalando módulos em ${ROOT}"
make INSTALL_MOD_PATH="${ROOT}" modules_install > "${SRC_DIR}/make.modules_install.log" 2>&1 || err "falha em modules_install"

# Instala kernel (bzImage/vmlinuz e System.map) em ${ROOT}/boot
mkdir -p -- "${ROOT}/boot"
# Tentativa padrão 'make install' (dependente do distro-tools); se não houver, copia manualmente
if make INSTALL_PATH="${ROOT}/boot" install > "${SRC_DIR}/make.install.log" 2>&1; then
  log "make install OK"
else
  warn "make install indisponível — copiando artefatos manualmente"
  # Caminho do bzImage por arquitetura
  BZIMG="$(find arch -type f -name 'bzImage' | head -n1 || true)"
  [[ -n "${BZIMG}" ]] || err "bzImage não encontrado"
  cp -f -- "${BZIMG}" "${ROOT}/boot/vmlinuz-${KVER}"
  [[ -r "System.map" ]] && cp -f -- "System.map" "${ROOT}/boot/System.map-${KVER}" || true
fi

ok "kernel ${KVER} + módulos instalados"
echo "${KVER}" > "${SRC_DIR}/.kver"
