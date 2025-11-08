#!/usr/bin/env bash
# 00-bootstrap-stage0-pre_build.sh
# Hook de pré-build para binutils no bootstrap stage0 (mínimo, isolado em /tools)

set -euo pipefail

# ===== utilitários mínimos (integra com 01-adm-lib.sh se carregado) =====
log()  { command -v adm_step >/dev/null 2>&1 && adm_step "binutils" "stage0" "$* " || echo "[stage0-pre] $*"; }
ok()   { command -v adm_ok   >/dev/null 2>&1 && adm_ok "$*"   || echo "[stage0-pre][OK] $*"; }
warn() { command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[stage0-pre][WARN] $*"; }
err()  { command -v adm_err  >/dev/null 2>&1 && adm_err "$*"  || { echo "[stage0-pre][ERR] $*" >&2; exit 1; } }

# ===== contexto esperado do orquestrador =====
# ROOT: rootfs do stage (ex.: /usr/src/adm/state/bootstrap/stage0/rootfs)
# SRC_DIR: diretório do source extraído (binutils-2.45)
# BUILD_DIR: diretório de build (use out-of-tree)
# JOBS: graus de paralelismo (opcional)
: "${ROOT:?ROOT não definido (rootfs do stage0)}"
: "${SRC_DIR:?SRC_DIR não definido (árvore do binutils)}"
: "${BUILD_DIR:=${SRC_DIR%/}-build}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"

# TARGET: triplet alvo (ex.: x86_64-linux-gnu, aarch64-linux-gnu)
# SYSROOT: sysroot efetivo dentro do stage (normalmente "/")
TARGET="${BOOTSTRAP_TARGET:-${TARGET:-}}"
SYSROOT="${BOOTSTRAP_SYSROOT:-${SYSROOT:-/}}"

# Em stage0, prefix recomendado: /tools (isolado)
PREFIX="/tools"

log "preparando build out-of-tree (BUILD_DIR: ${BUILD_DIR})"
mkdir -p -- "${BUILD_DIR}"

# Ambiente minimal (perfil 'minimal' deve estar ativo; ainda assim reforçamos)
: "${CFLAGS:="-O2 -pipe"}"
: "${CXXFLAGS:="-O2 -pipe"}"
# Estático no stage0 é opcional; se quiser estático duro, descomente:
# : "${LDFLAGS:="-static"}"

# Caminhos (para encadear com GCC pass1, quando existir)
export PATH="${ROOT}${PREFIX}/bin:${PATH}"

# Matriz de configure mínima (sem NLS/plugins/gold/multilib/gprofng)
CONF_ARGS=(
  "--prefix=${PREFIX}"
  "--with-sysroot=${SYSROOT}"
  "--disable-nls"
  "--disable-werror"
  "--disable-multilib"
  "--enable-gold=no"
  "--enable-ld=yes"
  "--enable-plugins=no"
  "--disable-gprofng"
  "--disable-gdb"
)

# Se TARGET foi informado (cross real), adiciona
if [[ -n "${TARGET}" ]]; then
  CONF_ARGS+=( "--target=${TARGET}" )
  log "usando TARGET=${TARGET}"
fi

# Triplet de compilação/host: no stage0, normalmente use o triplet do host de build
if command -v gcc >/dev/null 2>&1 && gcc -dumpmachine >/dev/null 2>&1; then
  BUILD_TRIPLET="$(gcc -dumpmachine)"
  CONF_ARGS+=( "--build=${BUILD_TRIPLET}" "--host=${BUILD_TRIPLET}" )
fi

# Executa configure (fora da árvore)
log "executando configure (mínimo)"
pushd "${BUILD_DIR}" >/dev/null
set +e
../configure "${CONF_ARGS[@]}" CFLAGS="${CFLAGS}" CXXFLAGS="${CXXFLAGS}" LDFLAGS="${LDFLAGS:-}" >"${BUILD_DIR}/configure.log" 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  warn "configure falhou; removendo LDFLAGS e tentando novamente (fallback dinâmico)"
  ../configure "${CONF_ARGS[@]}" CFLAGS="${CFLAGS}" CXXFLAGS="${CXXFLAGS}" >"${BUILD_DIR}/configure.log" 2>&1
fi

ok "configure concluído (veja ${BUILD_DIR}/configure.log)"
popd >/dev/null

# Compila (somente prepara; build efetivo é no post_build)
log "build: make (check rápido de dependências)"
ok "pre_build pronto; prossiga para post_build"
