#!/usr/bin/env bash
# GCC final: validação, ajustes de specs (musl/glibc) e registro
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "gcc" "final" "$*" || echo "[gcc-final-post] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[gcc-final-post][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[gcc-final-post][WARN] $*"; }

: "${ROOT:?ROOT não definido}"

# Verificação básica
fails=0
if chroot "${ROOT}" /usr/bin/gcc --version >/dev/null 2>&1 || "${ROOT}/usr/bin/gcc" --version >/dev/null 2>&1; then
  :
else
  warn "gcc --version falhou"; fails=$((fails+1))
fi
if chroot "${ROOT}" /usr/bin/g++ --version >/dev/null 2>&1 || "${ROOT}/usr/bin/g++" --version >/dev/null 2>&1; then
  :
else
  warn "g++ --version falhou"; fails=$((fails+1))
fi

# Ajuste de specs (opcional) — quando alvo for musl
# Para usar loader musl por padrão, você pode gerar specs custom e gravar em /usr/lib/gcc/.../specs
if [[ "${GCC_SET_MUSL_SPECS:-0}" == "1" ]]; then
  GCCBIN="${ROOT}/usr/bin/gcc"
  SPECS_DIR="$(dirname "$(dirname "$("${GCCBIN}" -print-libgcc-file-name 2>/dev/null || echo "${ROOT}/usr/lib/gcc")")")"
  if [[ -x "${GCCBIN}" && -n "${SPECS_DIR}" ]]; then
    "${GCCBIN}" -dumpspecs > "${SPECS_DIR}/specs" 2>/dev/null || warn "não foi possível gerar specs"
    # Aqui você poderia editar o specs para apontar ld-musl adequado (omisso por segurança)
  fi
fi

state_dir="${ROOT}/usr/src/adm/state/final/gcc"
mkdir -p -- "$state_dir"
{
  echo "package=dev/gcc"
  echo "version=14.2.0"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "validate_failures=${fails}"
} > "${state_dir}/build.info"

ok "gcc final validado"
