#!/usr/bin/env bash
# Binutils final: configurar com plugins, ld.bfd (gold opcional), /usr
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "binutils" "final" "$*" || echo "[binutils-final-pre] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[binutils-final-pre][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[binutils-final-pre][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[binutils-final-pre][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}-build-final}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

PREFIX="/usr"
mkdir -p -- "${BUILD_DIR}"

# Plugins e ld.bfd; gold opcional via BINUTILS_GOLD=1
CONF_ARGS=(
  "--prefix=${PREFIX}"
  "--enable-ld=yes"
  "--enable-plugins"
  "--disable-werror"
  "--with-system-zlib"
)

if [[ "${BINUTILS_GOLD:-0}" == "1" ]]; then
  CONF_ARGS+=( "--enable-gold=yes" )
else
  CONF_ARGS+=( "--enable-gold=no" )
fi

pushd "${BUILD_DIR}" >/dev/null
../configure "${CONF_ARGS[@]}" > "${BUILD_DIR}/configure.log" 2>&1 || err "configure falhou (veja logs)"
ok "configure concluído"
popd >/dev/null
