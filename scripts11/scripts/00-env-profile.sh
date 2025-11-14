#!/usr/bin/env bash
# 00-env-profiles.sh
# Núcleo de ambiente + sistema de perfis do ADM.
# ----------------------------------------------------------------------
# Configuração de shell e segurança básica
# ----------------------------------------------------------------------
# Exigir bash (evita comportamento estranho em sh/dash)
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 00-env-profiles.sh requer bash." >&2
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'
# ----------------------------------------------------------------------
# Logging mínimo (01-log-ui.sh pode complementar depois)
# ----------------------------------------------------------------------
adm__log_ts() {
    # timestamp simples
    date +"%Y-%m-%d %H:%M:%S"
}

adm_info() {
    printf '[%s] [INFO] %s\n' "$(adm__log_ts)" "$*" >&2
}

adm_warn() {
    printf '[%s] [WARN] %s\n' "$(adm__log_ts)" "$*" >&2
}

adm_error() {
    printf '[%s] [ERRO] %s\n' "$(adm__log_ts)" "$*" >&2
}

adm_die() {
    adm_error "$*"
    exit 1
}

# ----------------------------------------------------------------------
# Constantes e variáveis globais do ADM
# ----------------------------------------------------------------------

# Diretório raiz do ADM (padrão fixo, pode ser sobrescrito via env antes de dar source)
ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"

# Outros caminhos derivados (podem ser ajustados pelos scripts superiores, se necessário)
ADM_SCRIPTS="${ADM_SCRIPTS:-$ADM_ROOT/scripts}"
ADM_REPO="${ADM_REPO:-$ADM_ROOT/repo}"
ADM_CACHE="${ADM_CACHE:-$ADM_ROOT/cache}"
ADM_SOURCES="${ADM_SOURCES:-$ADM_ROOT/sources}"
ADM_WORK="${ADM_WORK:-$ADM_ROOT/work}"
ADM_DB="${ADM_DB:-$ADM_ROOT/db}"
ADM_PROFILES_DIR="${ADM_PROFILES_DIR:-$ADM_ROOT/profiles}"

# Perfil padrão, caso não seja definido externamente
ADM_PROFILE="${ADM_PROFILE:-normal}"

# Libc padrão (pode ser glibc ou musl; usado como hint, não força nada sozinho)
ADM_LIBC="${ADM_LIBC:-glibc}"

# Versão do "schema" de profile para futura evolução/migração
ADM_PROFILE_SCHEMA_VERSION="1"

# Lista de variáveis que um profile "completo e evoluído" deve fornecer
# (podem ser expandidas no futuro sem quebrar)
ADM_PROFILE_REQUIRED_VARS=(
    ADM_PROFILE
    ADM_PROFILE_SCHEMA_VERSION
    ADM_LIBC

    ADM_TARGET
    ADM_HOST
    ADM_BUILD
    ADM_SYSROOT

    CC
    CXX
    FC
    RUSTC
    GO
    AR
    RANLIB
    STRIP
    LD
    NM
    OBJCOPY
    OBJDUMP

    CFLAGS
    CXXFLAGS
    FCFLAGS
    LDFLAGS
    ASFLAGS
    CPPFLAGS
    MAKEFLAGS

    ADM_ENABLE_TESTS
    ADM_ENABLE_LTO
    ADM_ENABLE_PGO
    ADM_OPT_LEVEL
    ADM_HARDENING_FLAGS
)

# ----------------------------------------------------------------------
# Funções utilitárias
# ----------------------------------------------------------------------

adm_ensure_dir() {
    # Cria diretório se não existir, com mensagem de erro amigável se falhar.
    # Uso: adm_ensure_dir "/algum/caminho"
    local d="$1"
    if [ -z "$d" ]; then
        adm_die "adm_ensure_dir chamado com caminho vazio"
    fi

    if [ -d "$d" ]; then
        return 0
    fi

    if ! mkdir -p "$d"; then
        adm_die "Falha ao criar diretório: $d"
    fi
}

adm_detect_njobs() {
    # Detecta número de jobs (núcleos) de forma robusta.
    local n
    if command -v nproc >/dev/null 2>&1; then
        n="$(nproc || echo 1)"
    elif command -v getconf >/dev/null 2>&1; then
        n="$(getconf _NPROCESSORS_ONLN || echo 1)"
    else
        n="1"
    fi

    case "$n" in
        ''|*[!0-9]*) n="1" ;;
    esac

    echo "$n"
}

adm_detect_triplet() {
    # Tenta detectar um triplet razoável baseado na arquitetura.
    # Não é perfeito, mas é um bom default.
    local arch os triple

    arch="$(uname -m 2>/dev/null || echo unknown)"
    os="$(uname -s 2>/dev/null || echo unknown)"

    case "$os" in
        Linux)
            case "$arch" in
                x86_64) triple="x86_64-unknown-linux-gnu" ;;
                i?86)   triple="i686-unknown-linux-gnu" ;;
                aarch64) triple="aarch64-unknown-linux-gnu" ;;
                arm*) triple="arm-unknown-linux-gnueabihf" ;;
                *) triple="${arch}-unknown-linux-gnu" ;;
            esac
            ;;
        *)
            triple="${arch}-unknown-${os,,}"  # pode virar algo estranho, mas é melhor que nada
            ;;
    esac

    echo "$triple"
}

adm_init_paths() {
    # Garante que os diretórios principais do ADM existem.
    adm_ensure_dir "$ADM_ROOT"
    adm_ensure_dir "$ADM_SCRIPTS"
    adm_ensure_dir "$ADM_REPO"
    adm_ensure_dir "$ADM_CACHE"
    adm_ensure_dir "$ADM_SOURCES"
    adm_ensure_dir "$ADM_WORK"
    adm_ensure_dir "$ADM_DB"
    adm_ensure_dir "$ADM_PROFILES_DIR"
}

# ----------------------------------------------------------------------
# Sistema de Profiles
# ----------------------------------------------------------------------

adm_profiles_list() {
    # Lista perfis disponíveis (nomes de arquivos *.profile).
    if [ ! -d "$ADM_PROFILES_DIR" ]; then
        return 0
    fi

    local f
    for f in "$ADM_PROFILES_DIR"/*.profile; do
        [ -e "$f" ] || continue
        basename "$f" .profile
    done | sort
}

adm_profile_file_path() {
    # Echo do caminho de um profile pelo nome.
    # Uso: adm_profile_file_path normal
    local name="$1"
    if [ -z "$name" ]; then
        adm_die "adm_profile_file_path chamado com nome vazio"
    fi
    echo "$ADM_PROFILES_DIR/$name.profile"
}

adm_profiles_generate_default() {
    # Gera profile default para um nome dado (aggressive, normal, minimal).
    # Só é chamado quando o arquivo ainda não existe.
    local name="$1"
    local path
    path="$(adm_profile_file_path "$name")"

    local njobs
    njobs="$(adm_detect_njobs)"

    adm_info "Criando profile padrão: $name ($path)"

    case "$name" in
        aggressive)
            cat >"$path" <<EOF
# Profile gerado automaticamente pelo ADM
ADM_PROFILE="$name"
ADM_PROFILE_SCHEMA_VERSION="$ADM_PROFILE_SCHEMA_VERSION"

ADM_LIBC="${ADM_LIBC}"

ADM_TARGET="${ADM_TARGET:-$(adm_detect_triplet)}"
ADM_HOST="${ADM_HOST:-$(adm_detect_triplet)}"
ADM_BUILD="${ADM_BUILD:-$(adm_detect_triplet)}"
ADM_SYSROOT="\${ADM_SYSROOT:-/usr/src/adm/rootfs-stage1}"

ADM_OPT_LEVEL="-O3"
ADM_ENABLE_LTO="1"
ADM_ENABLE_PGO="0"
ADM_ENABLE_TESTS="1"

ADM_HARDENING_FLAGS="-fstack-protector-strong -D_FORTIFY_SOURCE=2 -fstack-clash-protection"

CFLAGS="\${ADM_OPT_LEVEL} -pipe -march=native -mtune=native \${ADM_HARDENING_FLAGS}"
CXXFLAGS="\${CFLAGS}"
FCFLAGS="\${ADM_OPT_LEVEL} -pipe"
LDFLAGS="-Wl,-O2"
ASFLAGS=""
CPPFLAGS=""

MAKEFLAGS="-j${njobs}"

CC="\${CC:-gcc}"
CXX="\${CXX:-g++}"
FC="\${FC:-gfortran}"
RUSTC="\${RUSTC:-rustc}"
GO="\${GO:-go}"
AR="\${AR:-ar}"
RANLIB="\${RANLIB:-ranlib}"
STRIP="\${STRIP:-strip}"
LD="\${LD:-ld}"
NM="\${NM:-nm}"
OBJCOPY="\${OBJCOPY:-objcopy}"
OBJDUMP="\${OBJDUMP:-objdump}"
EOF
            ;;
        normal)
            cat >"$path" <<EOF
# Profile gerado automaticamente pelo ADM
ADM_PROFILE="$name"
ADM_PROFILE_SCHEMA_VERSION="$ADM_PROFILE_SCHEMA_VERSION"

ADM_LIBC="${ADM_LIBC}"

ADM_TARGET="${ADM_TARGET:-$(adm_detect_triplet)}"
ADM_HOST="${ADM_HOST:-$(adm_detect_triplet)}"
ADM_BUILD="${ADM_BUILD:-$(adm_detect_triplet)}"
ADM_SYSROOT="\${ADM_SYSROOT:-/usr/src/adm/rootfs-stage1}"

ADM_OPT_LEVEL="-O2"
ADM_ENABLE_LTO="0"
ADM_ENABLE_PGO="0"
ADM_ENABLE_TESTS="1"

ADM_HARDENING_FLAGS="-fstack-protector-strong -D_FORTIFY_SOURCE=2"

CFLAGS="\${ADM_OPT_LEVEL} -pipe \${ADM_HARDENING_FLAGS}"
CXXFLAGS="\${CFLAGS}"
FCFLAGS="\${ADM_OPT_LEVEL} -pipe"
LDFLAGS="-Wl,-O1"
ASFLAGS=""
CPPFLAGS=""

MAKEFLAGS="-j${njobs}"

CC="\${CC:-gcc}"
CXX="\${CXX:-g++}"
FC="\${FC:-gfortran}"
RUSTC="\${RUSTC:-rustc}"
GO="\${GO:-go}"
AR="\${AR:-ar}"
RANLIB="\${RANLIB:-ranlib}"
STRIP="\${STRIP:-strip}"
LD="\${LD:-ld}"
NM="\${NM:-nm}"
OBJCOPY="\${OBJCOPY:-objcopy}"
OBJDUMP="\${OBJDUMP:-objdump}"
EOF
            ;;
        minimal)
            cat >"$path" <<EOF
# Profile gerado automaticamente pelo ADM (minimal - foco em toolchain/bootstrap)
ADM_PROFILE="$name"
ADM_PROFILE_SCHEMA_VERSION="$ADM_PROFILE_SCHEMA_VERSION"

ADM_LIBC="${ADM_LIBC}"

ADM_TARGET="${ADM_TARGET:-$(adm_detect_triplet)}"
ADM_HOST="${ADM_HOST:-$(adm_detect_triplet)}"
ADM_BUILD="${ADM_BUILD:-$(adm_detect_triplet)}"
ADM_SYSROOT="\${ADM_SYSROOT:-/usr/src/adm/rootfs-stage1}"

ADM_OPT_LEVEL="-O2"
ADM_ENABLE_LTO="0"
ADM_ENABLE_PGO="0"
ADM_ENABLE_TESTS="0"   # geralmente desliga testes no começo do bootstrap

ADM_HARDENING_FLAGS="-fstack-protector-strong -D_FORTIFY_SOURCE=2"

CFLAGS="\${ADM_OPT_LEVEL} -pipe \${ADM_HARDENING_FLAGS}"
CXXFLAGS="\${CFLAGS}"
FCFLAGS="\${ADM_OPT_LEVEL}"
LDFLAGS=""
ASFLAGS=""
CPPFLAGS=""

MAKEFLAGS="-j1"  # minimal, previsível

CC="\${CC:-gcc}"
CXX="\${CXX:-g++}"
FC="\${FC:-gfortran}"
RUSTC="\${RUSTC:-rustc}"
GO="\${GO:-go}"
AR="\${AR:-ar}"
RANLIB="\${RANLIB:-ranlib}"
STRIP="\${STRIP:-strip}"
LD="\${LD:-ld}"
NM="\${NM:-nm}"
OBJCOPY="\${OBJCOPY:-objcopy}"
OBJDUMP="\${OBJDUMP:-objdump}"
EOF
            ;;
        *)
            adm_die "Perfil desconhecido para geração default: $name"
            ;;
    esac

    # Verificar se o arquivo realmente foi criado
    if [ ! -f "$path" ]; then
        adm_die "Falha ao criar profile default: $path"
    fi
}

adm_profiles_ensure_defaults_exist() {
    # Garante que aggressive, normal e minimal existam.
    adm_ensure_dir "$ADM_PROFILES_DIR"

    local p
    for p in aggressive normal minimal; do
        local path
        path="$(adm_profile_file_path "$p")"
        if [ ! -f "$path" ]; then
            adm_profiles_generate_default "$p"
        fi
    done
}

adm_profile_unset_known_vars() {
    # Limpa variáveis de profile conhecidas para evitar lixo herdado
    local var
    for var in "${ADM_PROFILE_REQUIRED_VARS[@]}"; do
        unset "$var" 2>/dev/null || true
    done
}

adm_profile_validate_and_fill() {
    # Garante que todas as variáveis obrigatórias estão definidas;
    # se alguma estiver faltando, preenche com defaults conservadores
    # (isso mitiga perfis antigos/incompletos).
    local name="${ADM_PROFILE:-}"
    if [ -z "$name" ]; then
        name="normal"
        ADM_PROFILE="$name"
    fi

    local var
    for var in "${ADM_PROFILE_REQUIRED_VARS[@]}"; do
        # Usar parâmetro indireto com cuidado por causa do set -u
        if [ -z "${!var-}" ]; then
            case "$var" in
                ADM_PROFILE_SCHEMA_VERSION)
                    export ADM_PROFILE_SCHEMA_VERSION="$ADM_PROFILE_SCHEMA_VERSION"
                    ;;
                ADM_LIBC)
                    export ADM_LIBC="${ADM_LIBC:-glibc}"
                    ;;
                ADM_TARGET|ADM_HOST|ADM_BUILD)
                    export "$var"="$(adm_detect_triplet)"
                    ;;
                ADM_SYSROOT)
                    export ADM_SYSROOT="/usr/src/adm/rootfs-stage1"
                    ;;
                ADM_OPT_LEVEL)
                    export ADM_OPT_LEVEL="-O2"
                    ;;
                ADM_ENABLE_LTO|ADM_ENABLE_PGO|ADM_ENABLE_TESTS)
                    export "$var"="0"
                    ;;
                ADM_HARDENING_FLAGS)
                    export ADM_HARDENING_FLAGS="-fstack-protector-strong -D_FORTIFY_SOURCE=2"
                    ;;
                CC)
                    export CC="gcc"
                    ;;
                CXX)
                    export CXX="g++"
                    ;;
                FC)
                    export FC="gfortran"
                    ;;
                RUSTC)
                    export RUSTC="rustc"
                    ;;
                GO)
                    export GO="go"
                    ;;
                AR)
                    export AR="ar"
                    ;;
                RANLIB)
                    export RANLIB="ranlib"
                    ;;
                STRIP)
                    export STRIP="strip"
                    ;;
                LD)
                    export LD="ld"
                    ;;
                NM)
                    export NM="nm"
                    ;;
                OBJCOPY)
                    export OBJCOPY="objcopy"
                    ;;
                OBJDUMP)
                    export OBJDUMP="objdump"
                    ;;
                CFLAGS)
                    export CFLAGS="${ADM_OPT_LEVEL:-"-O2"} -pipe ${ADM_HARDENING_FLAGS:-}"
                    ;;
                CXXFLAGS)
                    export CXXFLAGS="${CFLAGS:-"-O2 -pipe"}"
                    ;;
                FCFLAGS)
                    export FCFLAGS="${ADM_OPT_LEVEL:-"-O2"}"
                    ;;
                LDFLAGS)
                    export LDFLAGS="-Wl,-O1"
                    ;;
                ASFLAGS|CPPFLAGS)
                    export "$var"=""
                    ;;
                MAKEFLAGS)
                    export MAKEFLAGS="-j$(adm_detect_njobs)"
                    ;;
                *)
                    # fallback genérico
                    export "$var"=""
                    ;;
            esac
            adm_warn "Variável de profile '$var' estava ausente; usando default para perfil '$name'."
        fi
    done
}

adm_use_profile() {
    # Seleciona e carrega um profile pelo nome, com validação.
    # Uso: adm_use_profile normal
    local name="${1:-}"

    if [ -z "$name" ]; then
        name="${ADM_PROFILE:-normal}"
    fi

    adm_profiles_ensure_defaults_exist

    local f
    f="$(adm_profile_file_path "$name")"

    if [ ! -f "$f" ]; then
        adm_die "Profile '$name' não encontrado em '$f'"
    fi

    adm_info "Carregando profile: $name"

    # Limpar variáveis de profile conhecidas
    adm_profile_unset_known_vars

    # Carregar o arquivo de profile
    # shellcheck disable=SC1090
    if ! source "$f"; then
        adm_die "Falha ao carregar profile '$name' de '$f'"
    fi

    # Garantir que ADM_PROFILE está coerente
    ADM_PROFILE="${ADM_PROFILE:-$name}"
    export ADM_PROFILE

    # Validar e preencher variáveis faltantes
    adm_profile_validate_and_fill

    adm_info "Profile ativo: $ADM_PROFILE (schema v${ADM_PROFILE_SCHEMA_VERSION})"
}

adm_profiles_current_summary() {
    # Imprime um resumo do profile atual (útil para debug).
    cat <<EOF
ADM_PROFILE=${ADM_PROFILE:-<indefinido>}
ADM_LIBC=${ADM_LIBC:-<indefinido>}
ADM_TARGET=${ADM_TARGET:-<indefinido>}
ADM_HOST=${ADM_HOST:-<indefinido>}
ADM_BUILD=${ADM_BUILD:-<indefinido>}
ADM_SYSROOT=${ADM_SYSROOT:-<indefinido>}
CFLAGS=${CFLAGS:-<indefinido>}
CXXFLAGS=${CXXFLAGS:-<indefinido>}
LDFLAGS=${LDFLAGS:-<indefinido>}
MAKEFLAGS=${MAKEFLAGS:-<indefinido>}
ADM_ENABLE_TESTS=${ADM_ENABLE_TESTS:-<indefinido>}
ADM_ENABLE_LTO=${ADM_ENABLE_LTO:-<indefinido>}
ADM_ENABLE_PGO=${ADM_ENABLE_PGO:-<indefinido>}
EOF
}

# ----------------------------------------------------------------------
# Inicialização principal
# ----------------------------------------------------------------------

adm_init_env() {
    # Esta função deve ser chamada pelos outros scripts logo após dar source.
    # Ela garante:
    #  - diretórios principais criados
    #  - profiles default existentes
    #  - profile selecionado carregado e validado

    adm_init_paths

    # Se ADM_PROFILE veio do ambiente, respeitamos; senão ficamos em "normal"
    ADM_PROFILE="${ADM_PROFILE:-normal}"
    export ADM_PROFILE

    adm_use_profile "$ADM_PROFILE"
}

# ----------------------------------------------------------------------
# Comportamento ao ser executado diretamente
# ----------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Executado como script (em vez de ser "sourced")
    adm_info "00-env-profiles.sh foi executado diretamente."
    adm_info "Inicializando ambiente e carregando profile '${ADM_PROFILE}'..."
    adm_init_env
    echo
    echo "Resumo do profile atual:"
    adm_profiles_current_summary
    echo
    echo "Perfis disponíveis em '$ADM_PROFILES_DIR':"
    adm_profiles_list || true
fi
