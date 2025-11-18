#!/usr/bin/env bash
# 01-env.sh - Ambiente base do sistema ADM (LFS builder)
# Deve ser *sourced* pelos outros scripts:
#   . /usr/src/adm/scripts/01-env.sh

# Impedir execução direta
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Este script deve ser 'sourced', não executado diretamente." >&2
    exit 1
fi

# Guard para evitar carregar duas vezes
if [[ -n "${ADM_ENV_LOADED:-}" ]]; then
    return 0
fi

# Segurança básica
# (não usamos 'set -euo pipefail' aqui porque este arquivo é compartilhado;
#  os scripts chamadores é que devem configurar isso)
umask 022

###############################################################################
# 1. Paths e diretórios padrão
###############################################################################

# Diretório raiz do ADM (pode ser sobrescrito antes de dar source)
: "${ADM_ROOT:=/usr/src/adm}"

# Diretório de scripts
: "${ADM_SCRIPTS:=${ADM_ROOT}/scripts}"

# Diretórios principais
: "${ADM_SOURCES:=${ADM_ROOT}/sources}"
: "${ADM_BUILD:=${ADM_ROOT}/build}"
: "${ADM_LOGS:=${ADM_ROOT}/logs}"
: "${ADM_PKG:=${ADM_ROOT}/pkg}"
: "${ADM_CHROOT:=${ADM_ROOT}/chroot}"
: "${ADM_REPO:=${ADM_ROOT}/repo}"
: "${ADM_UPDATES:=${ADM_ROOT}/updates}"

# DB interno de pacotes e builds
: "${ADM_DB:=${ADM_ROOT}/db}"
: "${ADM_DB_PKG:=${ADM_DB}/packages}"
: "${ADM_DB_BUILD:=${ADM_DB}/builds}"

# Nome do host alvo (para cross)
: "${ADM_TARGET:=${LFS_TGT:-$(uname -m)-unknown-linux-gnu}}"

# Perfil padrão e libc padrão (podem ser sobrescritos pelo chamador)
: "${ADM_PROFILE:=normal}"     # aggressive | normal | minimal
: "${ADM_LIBC:=glibc}"        # glibc | musl

# Controle de 'march=native' (útil em cross ou builds genéricos)
: "${ADM_ALLOW_MARCH_NATIVE:=1}"   # 1 = permitido, 0 = desabilitado

# Número de jobs paralelos (padrão: nproc, fallback 4)
if command -v nproc >/dev/null 2>&1; then
    : "${ADM_JOBS:=$(nproc)}"
else
    : "${ADM_JOBS:=4}"
fi

###############################################################################
# 2. Funções utilitárias de diretórios e checagem
###############################################################################

adm_ensure_directories() {
    local d
    for d in \
        "$ADM_ROOT" "$ADM_SCRIPTS" "$ADM_SOURCES" "$ADM_BUILD" \
        "$ADM_LOGS" "$ADM_PKG" "$ADM_CHROOT" "$ADM_REPO" "$ADM_UPDATES" \
        "$ADM_DB" "$ADM_DB_PKG" "$ADM_DB_BUILD"
    do
        if [[ -e "$d" && ! -d "$d" ]]; then
            echo "ERRO: '$d' existe mas não é diretório." >&2
            return 1
        fi
        if [[ ! -d "$d" ]]; then
            mkdir -p "$d" || {
                echo "ERRO: não foi possível criar diretório '$d'." >&2
                return 1
            }
        fi
    done
    return 0
}

adm_detect_cpu() {
    # Detecção simples/robusta – não falha se ferramentas não existirem
    ADM_CPU_ARCH="$(uname -m 2>/dev/null || echo unknown)"
    ADM_CPU_CORES="$ADM_JOBS"
    ADM_CPU_FLAGS=""

    if command -v lscpu >/dev/null 2>&1; then
        ADM_CPU_FLAGS="$(lscpu 2>/dev/null | awk -F: '/Flags/ {print $2}' | xargs || true)"
    elif [[ -r /proc/cpuinfo ]]; then
        ADM_CPU_FLAGS="$(grep -m1 -i '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | xargs || true)"
    fi

    export ADM_CPU_ARCH ADM_CPU_CORES ADM_CPU_FLAGS
}

###############################################################################
# 3. Perfis de compilação: aggressive / normal / minimal
###############################################################################

# Flags base "seguras"
ADM_BASE_CFLAGS="-O2 -pipe"
ADM_BASE_LDFLAGS=""
ADM_BASE_CPPFLAGS=""
ADM_BASE_RUSTFLAGS=""
ADM_BASE_GOFLAGS=""

# PGO (Profile Guided Optimization) – flags gen/use
ADM_PGO_GEN_FLAGS_C="-fprofile-generate"
ADM_PGO_USE_FLAGS_C="-fprofile-use -fprofile-correction"

ADM_PGO_GEN_FLAGS_RUST="-Cprofile-generate"
ADM_PGO_USE_FLAGS_RUST="-Cprofile-use"

adm_profile_set_minimal() {
    # Pensado para cross-toolchain e builds mais previsíveis
    ADM_CFLAGS="$ADM_BASE_CFLAGS -g0"
    ADM_CXXFLAGS="$ADM_CFLAGS"
    ADM_LDFLAGS="$ADM_BASE_LDFLAGS"
    ADM_CPPFLAGS="$ADM_BASE_CPPFLAGS"
    ADM_RUSTFLAGS="$ADM_BASE_RUSTFLAGS"
    ADM_GOFLAGS="$ADM_BASE_GOFLAGS"
    ADM_MAKEFLAGS="-j${ADM_JOBS}"
    ADM_ENABLE_LTO=0
    ADM_ENABLE_PGO=0
}

adm_profile_set_normal() {
    # Meio termo: boa performance + segurança razoável
    local march_flag=""
    if [[ "$ADM_ALLOW_MARCH_NATIVE" -eq 1 ]]; then
        march_flag="-march=native -mtune=native"
    fi

    ADM_CFLAGS="-O2 -pipe -fstack-protector-strong -fno-plt ${march_flag}"
    ADM_CXXFLAGS="$ADM_CFLAGS"
    ADM_LDFLAGS="-Wl,-O1 -Wl,--as-needed"
    ADM_CPPFLAGS="-D_FORTIFY_SOURCE=2"
    ADM_RUSTFLAGS="-C opt-level=2"
    ADM_GOFLAGS=""
    ADM_MAKEFLAGS="-j${ADM_JOBS}"
    ADM_ENABLE_LTO=1
    ADM_ENABLE_PGO=0
}

adm_profile_set_aggressive() {
    # Tudo que dá para performance (usando com cuidado em produção)
    local march_flag=""
    if [[ "$ADM_ALLOW_MARCH_NATIVE" -eq 1 ]]; then
        march_flag="-march=native -mtune=native"
    fi

    ADM_CFLAGS="-O3 -pipe ${march_flag} -fno-plt -fgraphite-identity -floop-nest-optimize"
    ADM_CXXFLAGS="$ADM_CFLAGS"
    ADM_LDFLAGS="-Wl,-O1 -Wl,--as-needed"
    ADM_CPPFLAGS="-D_FORTIFY_SOURCE=2"
    ADM_RUSTFLAGS="-C opt-level=3"
    ADM_GOFLAGS="-ldflags=-s -ldflags=-w"
    ADM_MAKEFLAGS="-j${ADM_JOBS}"
    ADM_ENABLE_LTO=1
    ADM_ENABLE_PGO=1
}

###############################################################################
# 4. Ajustes específicos por libc (glibc vs musl)
###############################################################################

adm_profile_adjust_for_glibc() {
    # Ajustes pensados para glibc
    ADM_CPPFLAGS="${ADM_CPPFLAGS} -D_GNU_SOURCE"
}

adm_profile_adjust_for_musl() {
    # Ajustes pensados para musl
    ADM_CPPFLAGS="${ADM_CPPFLAGS} -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700"
}

###############################################################################
# 5. Aplicar perfil + libc
###############################################################################

adm_set_profile() {
    local profile="${1:-$ADM_PROFILE}"
    local libc="${2:-$ADM_LIBC}"

    case "$profile" in
        minimal)   ADM_PROFILE="minimal";   adm_profile_set_minimal ;;
        normal)    ADM_PROFILE="normal";    adm_profile_set_normal ;;
        aggressive)ADM_PROFILE="aggressive";adm_profile_set_aggressive ;;
        *)
            echo "ERRO: perfil desconhecido '$profile' (use: minimal|normal|aggressive)" >&2
            return 1
            ;;
    esac

    case "$libc" in
        glibc) ADM_LIBC="glibc"; adm_profile_adjust_for_glibc ;;
        musl)  ADM_LIBC="musl";  adm_profile_adjust_for_musl  ;;
        *)
            echo "ERRO: libc desconhecida '$libc' (use: glibc|musl)" >&2
            return 1
            ;;
    esac

    adm_apply_profile_env
}
adm_apply_profile_env() {
    # Exporta as variáveis de ambiente de compilação
    export ADM_PROFILE ADM_LIBC

    export CFLAGS="${ADM_CFLAGS}"
    export CXXFLAGS="${ADM_CXXFLAGS}"
    export LDFLAGS="${ADM_LDFLAGS}"
    export CPPFLAGS="${ADM_CPPFLAGS}"
    export RUSTFLAGS="${ADM_RUSTFLAGS}"
    export GOFLAGS="${ADM_GOFLAGS}"
    export MAKEFLAGS="${ADM_MAKEFLAGS}"

    # LTO
    if [[ "${ADM_ENABLE_LTO:-0}" -eq 1 ]]; then
        export CFLAGS="${CFLAGS} -flto"
        export CXXFLAGS="${CXXFLAGS} -flto"
        export LDFLAGS="${LDFLAGS} -flto"
        export RUSTFLAGS="${RUSTFLAGS} -Clto=fat"
    fi

    # PGO (apenas define flags gen/use; o 04-build-pkg.sh decide quando usar)
    export ADM_PGO_GEN_FLAGS_C ADM_PGO_USE_FLAGS_C
    export ADM_PGO_GEN_FLAGS_RUST ADM_PGO_USE_FLAGS_RUST
}

adm_log_env_info() {
    cat <<EOF
[ADM ENV]
  ADM_ROOT      = ${ADM_ROOT}
  ADM_SCRIPTS   = ${ADM_SCRIPTS}
  ADM_SOURCES   = ${ADM_SOURCES}
  ADM_BUILD     = ${ADM_BUILD}
  ADM_LOGS      = ${ADM_LOGS}
  ADM_PKG       = ${ADM_PKG}
  ADM_CHROOT    = ${ADM_CHROOT}
  ADM_REPO      = ${ADM_REPO}
  ADM_UPDATES   = ${ADM_UPDATES}
  ADM_DB        = ${ADM_DB}

  ADM_PROFILE   = ${ADM_PROFILE}
  ADM_LIBC      = ${ADM_LIBC}
  ADM_JOBS      = ${ADM_JOBS}
  ADM_ALLOW_MARCH_NATIVE = ${ADM_ALLOW_MARCH_NATIVE}

  CFLAGS        = ${CFLAGS:-}
  CXXFLAGS      = ${CXXFLAGS:-}
  LDFLAGS       = ${LDFLAGS:-}
  CPPFLAGS      = ${CPPFLAGS:-}
  RUSTFLAGS     = ${RUSTFLAGS:-}
  GOFLAGS       = ${GOFLAGS:-}
  MAKEFLAGS     = ${MAKEFLAGS:-}
EOF
}

###############################################################################
# 6. Inicialização automática ao carregar o env
###############################################################################

# Garante que diretórios existem
adm_ensure_directories || {
    echo "ERRO: falha ao preparar diretórios base do ADM." >&2
    return 1
}

# Detecta CPU (não é crítico se falhar)
adm_detect_cpu || true

# Aplica perfil atual (ADM_PROFILE/ADM_LIBC podem ter vindo de fora)
adm_set_profile "$ADM_PROFILE" "$ADM_LIBC" || {
    echo "ERRO: falha ao aplicar perfil '${ADM_PROFILE}' com libc '${ADM_LIBC}'." >&2
    return 1
}

# Marca que o ambiente foi carregado
ADM_ENV_LOADED=1
export ADM_ENV_LOADED
