#!/usr/bin/env bash
# 00-bootstrap-stage0-pre_build.sh
# Hook de pré-build para GCC pass1 (stage0): gera compilador C cruzado mínimo em /tools.
# - Sem headers, sem libs extras; apenas gcc (C) + libgcc para o TARGET.

set -euo pipefail

# ===== utilitários (integra com 01-adm-lib.sh quando presente) =====
log()  { command -v adm_step >/dev/null 2>&1 && adm_step "gcc-pass1" "stage0" "$* " || echo "[gcc-pass1-pre] $*"; }
ok()   { command -v adm_ok   >/dev/null 2>&1 && adm_ok "$*"   || echo "[gcc-pass1-pre][OK] $*"; }
warn() { command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[gcc-pass1-pre][WARN] $*"; }
err()  { command -v adm_err  >/dev/null 2>&1 && adm_err "$*"  || { echo "[gcc-pass1-pre][ERR] $*" >&2; exit 1; } }

# ===== contexto esperado do orquestrador =====
# ROOT: rootfs do stage (ex.: /usr/src/adm/state/bootstrap/stage0/rootfs)
# SRC_DIR: diretório do source extraído (gcc-<ver>)
# BUILD_DIR: diretório de build "out-of-tree"
# JOBS: graus de paralelismo (opcional)
: "${ROOT:?ROOT não definido (rootfs do stage0)}"
: "${SRC_DIR:?SRC_DIR não definido (árvore do gcc)}"
: "${BUILD_DIR:=${SRC_DIR%/}-build}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

# TARGET triplet (ex.: x86_64-linux-gnu, aarch64-linux-gnu, riscv64-linux-gnu, ...)
TARGET="${BOOTSTRAP_TARGET:-${TARGET:-}}"
[[ -n "${TARGET}" ]] || err "TARGET não definido (ex.: BOOTSTRAP_TARGET=x86_64-linux-gnu)"

# SYSROOT do stage. No stage0, é o / do rootfs do stage.
SYSROOT="${BOOTSTRAP_SYSROOT:-${SYSROOT:-/}}"

PREFIX="/tools"

# Garante diretório de build out-of-tree
log "preparando BUILD_DIR=${BUILD_DIR}"
mkdir -p -- "${BUILD_DIR}"

# ===== Prérequisitos de precisão (gmp/mpfr/mpc) =====
# Estratégia:
# (1) se diretórios 'gmp', 'mpfr', 'mpc' já existirem dentro de SRC_DIR, usa in-tree;
# (2) se NÃO existirem, e existir 'contrib/download_prerequisites', tenta baixar (internet necessária);
# (3) se nem (1) nem (2), avisa — build pode falhar por falta dos prereqs.
pushd "${SRC_DIR}" >/dev/null
if [[ -d gmp && -d mpfr && -d mpc ]]; then
  log "prérequisitos de precisão já vendorizados (gmp/mpfr/mpc)."
elif [[ -x contrib/download_prerequisites ]]; then
  warn "baixando gmp/mpfr/mpc via contrib/download_prerequisites (requer rede)"
  ./contrib/download_prerequisites >/dev/null 2>&1 || warn "download_prerequisites falhou; tentando sem vendorizar (pode falhar)"
else
  warn "gmp/mpfr/mpc não encontrados; prosseguindo (pode falhar se não estiverem no sistema)"
fi
popd >/dev/null

# ===== Ambiente mínimo do stage0 =====
# Evite LTO e outros recursos pesados. Apenas C.
: "${CFLAGS:="-O2 -pipe"}"
: "${CXXFLAGS:="-O2 -pipe"}"
# Se quiser tentar estático (nem sempre prático no gcc): export LDFLAGS="-static"

# Garantir prioridade de /tools/bin (binutils pass1 e, futuramente, gcc pass1)
export PATH="${ROOT}${PREFIX}/bin:${PATH}"

# ===== Matriz de configure para pass1 (sem headers) =====
# Referência: estilo LFS, adaptado ao seu ADM.
CONF_ARGS=(
  "--prefix=${PREFIX}"
  "--target=${TARGET}"
  "--with-sysroot=${SYSROOT}"
  "--with-newlib"
  "--without-headers"
  "--enable-languages=c"
  "--disable-nls"
  "--disable-shared"
  "--disable-threads"
  "--disable-libatomic"
  "--disable-libgomp"
  "--disable-libitm"
  "--disable-libmudflap"
  "--disable-libquadmath"
  "--disable-libsanitizer"
  "--disable-libssp"
  "--disable-libvtv"
  "--disable-multilib"
  "--disable-lto"
  "--disable-bootstrap"
  "--disable-plugin"
)

# Triplet de build/host (do compilador do host atual)
if command -v gcc >/dev/null 2>&1 && gcc -dumpmachine >/dev/null 2>&1; then
  BUILD_TRIPLET="$(gcc -dumpmachine)"
  CONF_ARGS+=( "--build=${BUILD_TRIPLET}" "--host=${BUILD_TRIPLET}" )
fi

log "executando configure (pass1: C-only, without-headers)"
pushd "${BUILD_DIR}" >/dev/null
set +e
../configure "${CONF_ARGS[@]}" CFLAGS="${CFLAGS}" CXXFLAGS="${CXXFLAGS}" LDFLAGS="${LDFLAGS:-}" >"${BUILD_DIR}/configure.log" 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  warn "configure falhou; removendo LDFLAGS e tentando novamente"
  ../configure "${CONF_ARGS[@]}" CFLAGS="${CFLAGS}" CXXFLAGS="${CXXFLAGS}" >"${BUILD_DIR}/configure.log" 2>&1
fi

ok "configure concluído (veja ${BUILD_DIR}/configure.log)"

# Dica de sequência: o build real fica no hook post_build (para manter logs separados).
ok "pre_build pronto; prossiga para post_build"
popd >/dev/null
