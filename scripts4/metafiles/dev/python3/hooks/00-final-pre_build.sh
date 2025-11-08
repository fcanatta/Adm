#!/usr/bin/env bash
# Python3 final — pré-build (configure)
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "python3" "final" "$*" || echo "[python3-pre] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[python3-pre][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[python3-pre][WARN] $*"; }
err(){ command -v adm_err >/dev/null 2>&1 && adm_err "$*" || { echo "[python3-pre][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:=${SRC_DIR%/}-build-final}"
: "${JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"
: "${PREFIX:=/usr}"

mkdir -p -- "${BUILD_DIR}"
cd "${SRC_DIR}"

# Detectar libc alvo (musl vs glibc) — impacta algumas opções
LIBC_KIND="glibc"
if grep -qi musl /lib*/libc.musl* 2>/dev/null || (ldd --version 2>&1 | grep -qi musl); then
  LIBC_KIND="musl"
fi

CONF_ARGS=(
  "--prefix=${PREFIX}"
  "--enable-shared"
  "--with-system-ffi"
  "--with-system-expat"
  "--with-ensurepip=install"
  "--without-pymalloc"           # menor fragmentação/overhead geral; ajuste se preferir
)

# Otimizações (se o perfil agressivo habilitar LTO/PGO)
# PGO com 'profile-opt' é custoso; por padrão ligamos só 'enable-optimizations' (PGO+LTO leve).
if [[ "${PY_ENABLE_OPTIMIZATIONS:-1}" = "1" ]]; then
  CONF_ARGS+=( "--enable-optimizations" )
fi
if [[ "${ADM_ENABLE_LTO:-}" =~ ^(thin|full|on|1)$ ]]; then
  CONF_ARGS+=( "--with-lto" )
fi

# Em musl, evitar dependências não essenciais e manter build previsível
if [[ "${LIBC_KIND}" = "musl" ]]; then
  # Essas opções mantêm a compatibilidade ampla com musl
  CONF_ARGS+=( "--enable-ipv6" )
fi

# Respeitar flags de ambiente (perfis). Adicionamos -fPIC por segurança com --enable-shared
: "${CFLAGS:=-O2 -pipe}"
: "${CXXFLAGS:=-O2 -pipe}"
export CFLAGS="${CFLAGS} -fPIC"
export CXXFLAGS="${CXXFLAGS} -fPIC"

# Diretório de build separado (recomendado pelo projeto)
cd "${BUILD_DIR}"
"${SRC_DIR}/configure" "${CONF_ARGS[@]}" > "${BUILD_DIR}/configure.log" 2>&1 \
  || err "configure falhou (veja ${BUILD_DIR}/configure.log)"

ok "configure concluído (libc=${LIBC_KIND})"
