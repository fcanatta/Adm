#!/usr/bin/env bash
# GNU make — pré-build (configure para /usr, out-of-tree opcional)

set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "make" "final" "$*" || echo "[make-pre] $*"; }
ok(){ command -v adm_ok   >/dev/null 2>&1 && adm_ok "$*"   || echo "[make-pre][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[make-pre][WARN] $*"; }
err(){ command -v adm_err  >/dev/null 2>&1 && adm_err "$*"  || { echo "[make-pre][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"

# make suporta in-tree; mas manteremos build dir separado p/ limpeza e logs
: "${BUILD_DIR:=${SRC_DIR%/}-build}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"
: "${PREFIX:=/usr}"

mkdir -p -- "${BUILD_DIR}"

# Flags sensatas; perfis podem sobrescrever via ambiente
: "${CFLAGS:= -O2 -pipe }"
: "${CXXFLAGS:= -O2 -pipe }"

# Alguns ambientes pedem 'FORCE_UNSAFE_CONFIGURE=1' quando rodando como root
export FORCE_UNSAFE_CONFIGURE=1

# Configure
pushd "${BUILD_DIR}" >/dev/null
set +e
"${SRC_DIR}/configure" --prefix="${PREFIX}" CFLAGS="${CFLAGS}" CXXFLAGS="${CXXFLAGS}" > "${BUILD_DIR}/configure.log" 2>&1
rc=$?; set -e
[[ $rc -eq 0 ]] || err "configure falhou (veja ${BUILD_DIR}/configure.log)"
ok "configure concluído"
popd >/dev/null
