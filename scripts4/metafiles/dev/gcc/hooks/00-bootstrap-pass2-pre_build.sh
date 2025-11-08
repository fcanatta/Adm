#!/usr/bin/env bash
# 00-bootstrap-pass2-pre_build.sh
# GCC pass2: usa headers+libc do stage, constrói C/C++ e libstdc++ para TARGET.

set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "gcc-pass2" "bootstrap" "$*" || echo "[gcc-pass2-pre] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[gcc-pass2-pre][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[gcc-pass2-pre][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[gcc-pass2-pre][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}-build-pass2}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"
TARGET="${BOOTSTRAP_TARGET:-${TARGET:-}}"; [[ -n "${TARGET}" ]] || err "TARGET não definido"
SYSROOT="${BOOTSTRAP_SYSROOT:-${SYSROOT:-/}}"

# Estratégia: instalar pass2 ainda em /tools, mas linkando para libc do stage em ${ROOT}/usr.
PREFIX="/tools"
export PATH="${ROOT}${PREFIX}/bin:${PATH}"

# Prérequisitos (gmp/mpfr/mpc/isl) — vendorizar ou baixar
pushd "${SRC_DIR}" >/dev/null
if [[ -x contrib/download_prerequisites ]]; then
  ./contrib/download_prerequisites >/dev/null 2>&1 || warn "download_prerequisites falhou; prosseguindo sem vendor"
fi
popd >/dev/null

mkdir -p -- "${BUILD_DIR}"

# Flags moderadas; sem LTO
: "${CFLAGS:="-O2 -pipe"}"
: "${CXXFLAGS:="-O2 -pipe"}"

CONF_ARGS=(
  "--prefix=${PREFIX}"
  "--target=${TARGET}"
  "--with-sysroot=${SYSROOT}"
  "--enable-languages=c,c++"
  "--disable-multilib"
  "--disable-nls"
  "--disable-libsanitizer"
  "--disable-libquadmath"
  "--disable-libmudflap"
  "--disable-libssp"
  "--disable-libvtv"
  "--disable-bootstrap"
)

# Build/host
if command -v gcc >/dev/null 2>&1 && gcc -dumpmachine >/dev/null 2>&1; then
  BH="$(gcc -dumpmachine)"
  CONF_ARGS+=( "--build=${BH}" "--host=${BH}" )
fi

log "configure (pass2)"
pushd "${BUILD_DIR}" >/dev/null
set +e
../configure "${CONF_ARGS[@]}" CFLAGS="${CFLAGS}" CXXFLAGS="${CXXFLAGS}" >"${BUILD_DIR}/configure.pass2.log" 2>&1
rc=$?; set -e
if [[ $rc -ne 0 ]]; then
  warn "configure falhou; tentando sem CXXFLAGS custom"
  ../configure "${CONF_ARGS[@]}" CFLAGS="${CFLAGS}" >"${BUILD_DIR}/configure.pass2.log" 2>&1
fi
ok "configure concluído"
popd >/dev/null
