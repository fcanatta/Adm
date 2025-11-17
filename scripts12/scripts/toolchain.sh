#!/usr/bin/env bash
# toolchain.sh – Orquestrador EXTREMO de toolchain ao estilo LFS, 100% ADM.
#
# Estágios:
#   bootstrap  → binutils (pass1), gcc (pass1), headers kernel
#   glibc      → glibc (base) usando o gcc/binutils cross
#   final      → gcc final, libs extras
#   full       → bootstrap + glibc + final
#
# Ele NÃO mexe direto em configure/make;
# ele usa o "adm" para instalar os pacotes:
#   binutils, gcc, linux, glibc, gmp, mpfr, mpc, isl
#
# Convenções:
#   - Target padrão: saída de "gcc -dumpmachine" ou x86_64-unknown-linux-gnu
#   - PREFIX padrão: /usr/src/adm/cross/${TARGET}
#   - ROOTFS:        /usr/src/adm/cross/${TARGET}/rootfs
#
#   Ele exporta variáveis para os scripts de build:
#     ADM_TC_STAGE  = bootstrap|glibc|final
#     ADM_TC_TARGET = triplet (ex: x86_64-unknown-linux-gnu)
#     ADM_TC_PREFIX = prefixo do toolchain
#     ADM_TC_ROOTFS = rootfs alvo
#
#   Seus hooks/build_core podem usar essas variáveis.

ADM_ROOT="/usr/src/adm"
ADM_SCRIPTS="$ADM_ROOT/scripts"
ADM_REPO="$ADM_ROOT/repo"
ADM_TC_ROOT="/usr/src/adm/cross"

# -----------------------------
# Cores e estilo
# -----------------------------
if [ -t 1 ]; then
    TC_CLR_RESET="\033[0m"
    TC_CLR_BOLD="\033[1m"
    TC_CLR_DIM="\033[2m"
    TC_CLR_RED="\033[31m"
    TC_CLR_GREEN="\033[32m"
    TC_CLR_YELLOW="\033[33m"
    TC_CLR_BLUE="\033[34m"
    TC_CLR_MAGENTA="\033[35m"
    TC_CLR_CYAN="\033[36m"
else
    TC_CLR_RESET=""
    TC_CLR_BOLD=""
    TC_CLR_DIM=""
    TC_CLR_RED=""
    TC_CLR_GREEN=""
    TC_CLR_YELLOW=""
    TC_CLR_BLUE=""
    TC_CLR_MAGENTA=""
    TC_CLR_CYAN=""
fi

TC_HAVE_UI=0
# ui.sh é opcional
if [ -r "$ADM_SCRIPTS/ui.sh" ]; then
    # shellcheck source=/usr/src/adm/scripts/ui.sh
    . "$ADM_SCRIPTS/ui.sh" && TC_HAVE_UI=1
fi

# -----------------------------
# Logging
# -----------------------------
tc_log_info() {
    local msg="$*"
    if [ "$TC_HAVE_UI" -eq 1 ] && declare -F adm_ui_log_info >/dev/null 2>&1; then
        adm_ui_log_info "$msg"
    else
        printf "%b[TC][INFO]%b %s\n" "$TC_CLR_CYAN" "$TC_CLR_RESET" "$msg" >&2
    fi
}

tc_log_warn() {
    local msg="$*"
    if [ "$TC_HAVE_UI" -eq 1 ] && declare -F adm_ui_log_warn >/dev/null 2>&1; then
        adm_ui_log_warn "$msg"
    else
        printf "%b[TC][WARN]%b %s\n" "$TC_CLR_YELLOW" "$TC_CLR_RESET" "$msg" >&2
    fi
}

tc_log_error() {
    local msg="$*"
    if [ "$TC_HAVE_UI" -eq 1 ] && declare -F adm_ui_log_error >/dev/null 2>&1; then
        adm_ui_log_error "$msg"
    else
        printf "%b[TC][ERROR]%b %s\n" "$TC_CLR_RED" "$TC_CLR_RESET" "$msg" >&2
    fi
}

tc_die() {
    tc_log_error "$*"
    exit 1
}

tc_trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

tc_ts() {
    date +"%Y%m%d-%H%M%S"
}

# -----------------------------
# Detectar 'adm'
# -----------------------------
tc_find_adm() {
    if command -v adm >/dev/null 2>&1; then
        printf 'adm\n'
        return 0
    fi
    # fallback: /usr/src/adm/scripts/adm
    if [ -x "$ADM_SCRIPTS/adm" ]; then
        printf '%s\n' "$ADM_SCRIPTS/adm"
        return 0
    fi
    tc_die "Ferramenta 'adm' não encontrada nem em \$PATH nem em $ADM_SCRIPTS/adm"
}

ADM_BIN="$(tc_find_adm)"

# -----------------------------
# Detectar target padrão
# -----------------------------
tc_detect_target() {
    local t=""
    if command -v gcc >/dev/null 2>&1; then
        t="$(gcc -dumpmachine 2>/dev/null || echo "")"
    fi
    [ -z "$t" ] && t="x86_64-unknown-linux-gnu"
    printf '%s\n' "$t"
}

# -----------------------------
# Ambiente do toolchain
# -----------------------------
tc_setup_env() {
    local target="$1"
    [ -z "$target" ] && target="$(tc_detect_target)"

    export ADM_TC_TARGET="$target"
    export ADM_TC_PREFIX="$ADM_TC_ROOT/$target"
    export ADM_TC_ROOTFS="$ADM_TC_PREFIX/rootfs"

    mkdir -p "$ADM_TC_PREFIX" "$ADM_TC_ROOTFS" || tc_die "Falha ao criar diretórios do toolchain: $ADM_TC_PREFIX / $ADM_TC_ROOTFS"

    # PATH preferindo o prefix do toolchain
    export PATH="$ADM_TC_PREFIX/bin:$PATH"

    tc_log_info "Ambiente do toolchain configurado:"
    tc_log_info "  ADM_TC_TARGET = $ADM_TC_TARGET"
    tc_log_info "  ADM_TC_PREFIX = $ADM_TC_PREFIX"
    tc_log_info "  ADM_TC_ROOTFS = $ADM_TC_ROOTFS"
    tc_log_info "  PATH          = $PATH"
}

# -----------------------------
# Wrapper para chamar 'adm install'
# -----------------------------
tc_run_install() {
    local stage="$1"   # bootstrap|glibc|final
    local pkg="$2"; shift 2 || true

    [ -z "$stage" ] && tc_die "tc_run_install: stage vazio"
    [ -z "$pkg" ] && tc_die "tc_run_install: pacote vazio"

    export ADM_TC_STAGE="$stage"

    tc_log_info "==> [${stage}] instalando pacote '${pkg}' (target=$ADM_TC_TARGET)"

    # Aqui só usamos a interface pública do adm: "adm install"
    # Flags extras (como --no-deps) podem ser passadas no shift acima.
    "$ADM_BIN" install "$pkg" "$@" || tc_die "Falha ao instalar pacote '${pkg}' no estágio '${stage}'"
}

# -----------------------------
# Status do toolchain
# -----------------------------
tc_status() {
    local target="$1"
    [ -z "$target" ] && target="$(tc_detect_target)"

    tc_setup_env "$target"

    printf "%b== STATUS TOOLCHAIN para %s ==%b\n" "$TC_CLR_BOLD" "$ADM_TC_TARGET" "$TC_CLR_RESET"

    # Se db.sh existir e o adm suportar "adm db list", podemos usar,
    # mas para não depender disso, vamos chamar "adm db" apenas se você
    # já tiver esse comando no seu CLI. Caso não tenha, cai para /usr/src/adm/db.sh.
    if "$ADM_BIN" db list 2>/dev/null | grep -q .; then
        tc_log_info "Pacotes de toolchain instalados (via adm db list | grep):"
        "$ADM_BIN" db list 2>/dev/null | grep -E '^(linux|binutils|gcc|glibc|gmp|mpfr|mpc|isl)' || true
    else
        # fallback simples: mostra se binários cross existem no prefix
        tc_log_warn "'adm db list' não disponível; mostrando apenas binários no prefixo."
        find "$ADM_TC_PREFIX/bin" -maxdepth 1 -type f 2>/dev/null || true
    fi
}

# -----------------------------
# Mostrar ambiente
# -----------------------------
tc_show_env() {
    local target="$1"
    tc_setup_env "$target"
    printf "%bAmbiente do toolchain%b\n" "$TC_CLR_BOLD" "$TC_CLR_RESET"
    printf "  ADM_TC_TARGET = %s\n" "$ADM_TC_TARGET"
    printf "  ADM_TC_PREFIX = %s\n" "$ADM_TC_PREFIX"
    printf "  ADM_TC_ROOTFS = %s\n" "$ADM_TC_ROOTFS"
    printf "  PATH          = %s\n" "$PATH"
    printf "  ADM_TC_STAGE  = %s\n" "${ADM_TC_STAGE:-<nenhum>}"
}

# -----------------------------
# Estágios LFS-like
# -----------------------------

# Bootstrap:
#   - gmp, mpfr, mpc, isl
#   - binutils (pass1)
#   - gcc (pass1)
#   - linux (headers)
tc_stage_bootstrap() {
    local target="$1"
    tc_log_info "==== [BOOTSTRAP] Iniciando bootstrap do toolchain ($target) ===="
    tc_setup_env "$target"

    # libs de suporte do gcc
    tc_run_install "bootstrap" "gmp"   --no-deps
    tc_run_install "bootstrap" "mpfr"  --no-deps
    tc_run_install "bootstrap" "mpc"   --no-deps
    tc_run_install "bootstrap" "isl"   --no-deps

    # binutils pass1
    tc_run_install "bootstrap" "binutils"

    # gcc pass1 (C only, sem libstdc++) – detalhes de stage ficam para build_core/profile
    tc_run_install "bootstrap" "gcc"

    # headers do kernel
    tc_run_install "bootstrap" "linux"

    tc_log_info "==== [BOOTSTRAP] Concluído para $ADM_TC_TARGET ===="
}

# Glibc:
#   - glibc (C library) usando gcc/binutils bootstrap
tc_stage_glibc() {
    local target="$1"
    tc_log_info "==== [GLIBC] Construindo glibc para ($target) ===="
    tc_setup_env "$target"

    tc_run_install "glibc" "glibc"

    tc_log_info "==== [GLIBC] Concluído para $ADM_TC_TARGET ===="
}

# Final:
#   - gcc final (C/C++ completo) usando glibc pronta
#   - (opcional) reconstruir binutils/gcc com libs finais (como no LFS)
tc_stage_final() {
    local target="$1"
    tc_log_info "==== [FINAL] Construindo GCC final para ($target) ===="
    tc_setup_env "$target"

    # gcc final – pacotes auxiliares já existem do bootstrap, então agora ele
    # constrói o compilador "definitivo". As diferenças de configure/flags
    # são responsabilidade do build_core/profile (via ADM_TC_STAGE=final).
    tc_run_install "final" "gcc"

    tc_log_info "==== [FINAL] Concluído para $ADM_TC_TARGET ===="
}

# Full:
#   - bootstrap + glibc + final
tc_stage_full() {
    local target="$1"
    tc_log_info "==== [FULL] Construindo toolchain completo para ($target) ===="
    tc_stage_bootstrap "$target"
    tc_stage_glibc "$target"
    tc_stage_final "$target"
    tc_log_info "==== [FULL] Toolchain completo finalizado: $ADM_TC_TARGET ===="
}
# -----------------------------
# Help
# -----------------------------
tc_print_help() {
    cat <<EOF
${TC_CLR_BOLD}Uso:${TC_CLR_RESET}
  toolchain.sh <comando> [opções]

${TC_CLR_BOLD}Comandos:${TC_CLR_RESET}
  bootstrap   [--target T]   Construir estágios iniciais (binutils+gcc pass1, kernel headers)
  glibc       [--target T]   Construir glibc para o target
  final       [--target T]   Construir GCC final (toolchain completo)
  full        [--target T]   Executar bootstrap + glibc + final
  status      [--target T]   Mostrar status/resumo do toolchain
  env         [--target T]   Mostrar ambiente (TARGET, PREFIX, ROOTFS)

${TC_CLR_BOLD}Opções:${TC_CLR_RESET}
  --target T   Triplet do target (ex: x86_64-unknown-linux-gnu). Se omitido, tenta gcc -dumpmachine.

${TC_CLR_BOLD}Exemplos:${TC_CLR_RESET}
  toolchain.sh bootstrap
  toolchain.sh full --target aarch64-linux-gnu
  toolchain.sh status
EOF
}

# -----------------------------
# Parser simples de --target
# -----------------------------
tc_parse_target() {
    local target=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --target)
                shift || true
                target="$1"
                ;;
            --target=*)
                target="${1#*=}"
                ;;
            -h|--help)
                tc_print_help
                exit 0
                ;;
            *)
                # devolve ao chamador
                break
                ;;
        esac
        shift || true
    done

    printf '%s\n' "$target"
}

# -----------------------------
# Dispatcher principal
# -----------------------------
tc_main() {
    local cmd="$1"
    shift || true

    case "$cmd" in
        ""|-h|--help)
            tc_print_help
            ;;
        bootstrap)
            local t
            t="$(tc_parse_target "$@")"
            tc_stage_bootstrap "$t"
            ;;
        glibc)
            local t
            t="$(tc_parse_target "$@")"
            tc_stage_glibc "$t"
            ;;
        final)
            local t
            t="$(tc_parse_target "$@")"
            tc_stage_final "$t"
            ;;
        full)
            local t
            t="$(tc_parse_target "$@")"
            tc_stage_full "$t"
            ;;
        status)
            local t
            t="$(tc_parse_target "$@")"
            tc_status "$t"
            ;;
        env)
            local t
            t="$(tc_parse_target "$@")"
            tc_show_env "$t"
            ;;
        *)
            tc_log_error "Comando desconhecido: $cmd"
            tc_print_help
            exit 1
            ;;
    esac
}

# -----------------------------
# Entrada
# -----------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    tc_main "$@"
fi
