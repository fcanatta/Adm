#!/usr/bin/env bash
# GCC final: configura para /usr, com NLS opcional, LTO, plugins; C/C++ por padrão.
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "gcc" "final" "$*" || echo "[gcc-final-pre] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[gcc-final-pre][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[gcc-final-pre][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[gcc-final-pre][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}-build-final}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

PREFIX="/usr"
LANGS="${GCC_LANGS:-c,c++}"    # personalize: ex.: c,c++,fortran,lto
ENABLE_NLS="${GCC_NLS:-1}"     # 1=on, 0=off
ENABLE_BOOTSTRAP="${GCC_BOOTSTRAP:-0}" # 1=on, 0=off
DISABLE_MULTILIB="${GCC_DISABLE_MULTILIB:-1}" # 1=disable

mkdir -p -- "${BUILD_DIR}"

# Vendorizar prereqs, se desejado
pushd "${SRC_DIR}" >/dev/null
if [[ -x contrib/download_prerequisites && "${GCC_VENDOR_PREREQS:-1}" == "1" ]]; then
  ./contrib/download_prerequisites >/dev/null 2>&1 || warn "download_prerequisites falhou; prosseguindo sem vendor"
fi
popd >/dev/null

CONF_ARGS=(
  "--prefix=${PREFIX}"
  "--enable-languages=${LANGS}"
  "--enable-shared"
  "--enable-threads=posix"
  "--enable-plugins"
  "--enable-lto"
  "--with-system-zlib"
)

[[ "${DISABLE_MULTILIB}" == "1" ]] && CONF_ARGS+=( "--disable-multilib" ) || true
[[ "${ENABLE_BOOTSTRAP}" == "1" ]] && CONF_ARGS+=( "--enable-bootstrap" ) || CONF_ARGS+=( "--disable-bootstrap" )
[[ "${ENABLE_NLS}" == "1" ]] && CONF_ARGS+=( "--enable-nls" ) || CONF_ARGS+=( "--disable-nls" )

# Triplets (nativo por padrão). Se desejar cruzado final, exporte TARGET/--target nos envs.
if [[ -n "${TARGET:-}" && "${TARGET}" != "$(gcc -dumpmachine 2>/dev/null || true)" ]]; then
  CONF_ARGS+=( "--host=$(gcc -dumpmachine 2>/dev/null || echo unknown)" "--target=${TARGET}" )
fi

# Flags razoáveis
: "${CFLAGS:="-O2 -pipe"}"
: "${CXXFLAGS:="-O2 -pipe"}"

pushd "${BUILD_DIR}" >/dev/null
../configure "${CONF_ARGS[@]}" CFLAGS="${CFLAGS}" CXXFLAGS="${CXXFLAGS}" > "${BUILD_DIR}/configure.log" 2>&1 || err "configure falhou"
ok "configure concluído"
popd >/dev/null
