#!/usr/bin/env bash
# glibc bootstrap pre_build: requer linux-headers já instalados no stage.
set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "glibc" "bootstrap" "$*" || echo "[glibc-pre] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[glibc-pre][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[glibc-pre][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[glibc-pre][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}-build}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"
TARGET="${BOOTSTRAP_TARGET:-${TARGET:-}}"; [[ -n "${TARGET}" ]] || err "TARGET não definido"
SYSROOT="${BOOTSTRAP_SYSROOT:-${SYSROOT:-/}}"

# Exige headers do kernel já presentes:
[[ -d "${ROOT}/usr/include" ]] || err "headers do kernel não encontrados em ${ROOT}/usr/include"

PREFIX="/usr"
mkdir -p -- "${BUILD_DIR}"

# glibc precisa de build out-of-tree; host/target variados
# Use '--host=$TARGET' quando cruzando; '--build=$(gcc -dumpmachine)' para o compilador do host
CONF_ARGS=(
  "--prefix=${PREFIX}"
  "--host=${TARGET}"
  "--build=$(gcc -dumpmachine 2>/dev/null || echo unknown)"
  "--with-headers=${SYSROOT}/usr/include"
  "--enable-kernel=4.14"
  "--disable-multilib"
  "--disable-werror"
)

pushd "${BUILD_DIR}" >/dev/null
set +e
../configure "${CONF_ARGS[@]}" > "${BUILD_DIR}/configure.log" 2>&1
rc=$?; set -e
if [[ $rc -ne 0 ]]; then
  warn "configure falhou; verifique dependências mínimas (bison, gawk, sed, make)"
  cat "${BUILD_DIR}/configure.log" | tail -n 50 || true
  err "configure glibc falhou"
fi
ok "configure concluído"
popd >/dev/null
