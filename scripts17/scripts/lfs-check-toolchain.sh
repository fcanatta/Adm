#!/usr/bin/env bash
#
# lfs-check-toolchain (versão estendida)
# --------------------------------------
# Checa o estado do toolchain LFS, tanto na fase cross quanto final.
#
# Modos:
#   host-cross   - rodar NO HOST, com LFS e LFS_TGT exportados (cross toolchain)
#   final        - rodar DENTRO DO CHROOT (toolchain final)
#   auto         - tenta detectar automaticamente
#
# Opções:
#   --strict     - trata qualquer WARN como erro (exit 1)
#   --log ARQ    - grava saída completa em ARQ (além da tela)
#
# Exemplos:
#   # host, checando cross:
#   export LFS=/mnt/lfs
#   export LFS_TGT=$(uname -m)-lfs-linux-gnu
#   lfs-check-toolchain host-cross --strict --log /tmp/toolchain-host.log
#
#   # dentro do chroot:
#   lfs-check-toolchain final
#

set -euo pipefail

MODE=""
STRICT=0
LOG_FILE=""

WARN_COUNT=0
ERROR_COUNT=0

color() {
    local code="$1"; shift
    if [[ -t 1 ]]; then
        printf "\033[%sm%s\033[0m" "$code" "$*"
    else
        printf "%s" "$*"
    fi
}

log_generic() {
    local level="$1"; shift
    local msg="$*"
    local prefix

    case "$level" in
        INFO)  prefix="$(color '1;32' '[INFO]')" ;;
        WARN)  prefix="$(color '1;33' '[WARN]')" ;;
        ERRO)  prefix="$(color '1;31' '[ERRO]')" ;;
        HEAD)  prefix="$(color '1;36' '====')" ;;
        *)     prefix="[$level]" ;;
    esac

    printf "%s %s\n" "$prefix" "$msg"

    if [[ -n "$LOG_FILE" ]]; then
        printf "[%s] %s\n" "$level" "$msg" >>"$LOG_FILE"
    fi
}

info()  { log_generic INFO "$*"; }
warn()  { WARN_COUNT=$((WARN_COUNT+1)); log_generic WARN "$*"; }
error() { ERROR_COUNT=$((ERROR_COUNT+1)); log_generic ERRO "$*"; }
head()  { log_generic HEAD "$*"; }

check_cmd() {
    local c
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            error "Comando obrigatório não encontrado: $c"
            exit 1
        fi
    done
}

########################################
# 1. Layout básico do LFS
########################################

check_lfs_layout() {
    local root="${1:-}"
    if [[ -z "$root" ]]; then
        warn "check_lfs_layout chamado sem raiz; pulando."
        return
    fi

    head "Checando layout básico em $root"

    local dir
    for dir in tools sources usr lib bin etc; do
        if [[ ! -d "$root/$dir" ]]; then
            warn "Diretório esperado ausente: $root/$dir"
        else
            info "OK: $root/$dir existe."
        fi
    done

    if [[ -d "$root/tools" ]]; then
        info "OK: $root/tools existe (cross-toolchain)."
    else
        warn "$root/tools não existe – cross-toolchain pode não estar configurado."
    fi
}

########################################
# 2. Dummy test (compilação de teste)
########################################

run_dummy_test() {
    local compiler="$1"     # ex: $LFS_TGT-gcc ou gcc
    local root_prefix="$2"  # ex: $LFS ou "" (para final)
    local label="$3"        # texto amigável

    head "Dummy test: $label"

    check_cmd "$compiler" readelf grep sed

    local tmpdir
    tmpdir="$(mktemp -d /tmp/lfs-toolchain-check.XXXXXX)"
    trap 'rm -rf "$tmpdir"' RETURN

    cat >"$tmpdir/dummy.c" << "EOF"
int main(void) { return 0; }
EOF

    info "Compilando dummy.c com $compiler ..."
    "$compiler" "$tmpdir/dummy.c" -v -Wl,--verbose -o "$tmpdir/a.out" &> "$tmpdir/dummy.log" || {
        error "Falha ao compilar dummy.c com $compiler"
        return 1
    }

    info "Program interpreter (readelf -l a.out | grep ': /lib'):"
    if ! readelf -l "$tmpdir/a.out" | grep ': /lib'; then
        warn "Nenhuma linha ': /lib' encontrada – confira manualmente."
    fi

    info "Start files (crt*.o):"
    local crt_pattern
    if [[ -n "$root_prefix" ]]; then
        crt_pattern="$root_prefix/lib.*/S?crt[1in].*succeeded"
    else
        crt_pattern="/usr/lib.*/S?crt[1in].*succeeded"
    fi
    if ! grep -E -o "$crt_pattern" "$tmpdir/dummy.log"; then
        warn "Start files (crt[1in]) não foram encontrados no dummy.log."
    fi

    info "Includes padrão:"
    local inc_prefix
    if [[ -n "$root_prefix" ]]; then
        inc_prefix="$root_prefix/usr/include"
    else
        inc_prefix="/usr/include"
    fi
    if ! grep -B4 "^ $inc_prefix" "$tmpdir/dummy.log"; then
        warn "Não encontrei entrada de includes para $inc_prefix."
    fi

    info "Caminhos de busca do linker:"
    if ! grep 'SEARCH.*/usr/lib' "$tmpdir/dummy.log" | sed 's/; /\n/g'; then
        warn "Não encontrei SEARCH_DIR para /usr/lib no dummy.log."
    fi

    info "Libc (libc.so.6):"
    if ! grep "/lib.*/libc.so.6 " "$tmpdir/dummy.log"; then
        warn "Não vi referência a libc.so.6 no dummy.log."
    fi

    info "Dynamic linker (linha 'found'):"
    if ! grep 'found' "$tmpdir/dummy.log"; then
        warn "Nenhuma linha 'found' no dummy.log (dynamic linker)."
    fi

    return 0
}

########################################
# 3. Checar specs por /tools
########################################

check_specs_for_tools() {
    local compiler="$1"    # ex: $LFS_TGT-gcc ou gcc
    local label="$2"

    head "Checando specs do $label por referências a /tools"

    local tmpfile
    tmpfile="$(mktemp /tmp/lfs-specs.XXXXXX)"
    "$compiler" -dumpspecs >"$tmpfile" || {
        warn "Não foi possível obter specs de $compiler"
        rm -f "$tmpfile"
        return
    }

    if grep -q '/tools' "$tmpfile"; then
        warn "FORAM encontradas referências a /tools nos specs de $compiler:"
        grep -n '/tools' "$tmpfile" | sed 's/^/  linha /'
    else
        info "Nenhuma referência a /tools nos specs de $compiler."
    fi

    rm -f "$tmpfile"
}

########################################
# 4. Versões de ferramentas
########################################

check_versions_host_cross() {
    : "${LFS_TGT:?LFS_TGT não definido}"

    head "Versões (host-cross)"

    if command -v "$LFS_TGT-gcc" >/dev/null 2>&1; then
        info "[$LFS_TGT-gcc] $("$LFS_TGT-gcc" --version | head -n1)"
    else
        warn "$LFS_TGT-gcc não encontrado no PATH."
    fi

    if command -v "$LFS_TGT-ld" >/dev/null 2>&1; then
        info "[$LFS_TGT-ld] $("$LFS_TGT-ld" --version | head -n1)"
    else
        warn "$LFS_TGT-ld não encontrado no PATH."
    fi

    if command -v "$LFS_TGT-as" >/dev/null 2>&1; then
        info "[$LFS_TGT-as] $("$LFS_TGT-as" --version | head -n1)"
    else
        warn "$LFS_TGT-as não encontrado no PATH."
    fi
}

check_versions_final() {
    head "Versões (final / dentro do chroot)"

    if command -v gcc >/dev/null 2>&1; then
        info "[gcc] $(gcc --version | head -n1)"
    else
        warn "gcc não encontrado no PATH."
    fi

    if command -v ld >/dev/null 2>&1; then
        info "[ld] $(ld --version | head -n1)"
    else
        warn "ld não encontrado no PATH."
    fi

    if command -v as >/dev/null 2>&1; then
        info "[as] $(as --version | head -n1)"
    else
        warn "as não encontrado no PATH."
    fi

    if command -v ldd >/dev/null 2>&1; then
        info "[ldd] $(ldd --version 2>&1 | head -n1)"
    else
        warn "ldd não encontrado no PATH."
    fi
}

########################################
# 5. Modos
########################################

check_host_cross() {
    : "${LFS:?LFS não definido}"
    : "${LFS_TGT:?LFS_TGT não definido}"

    head "Checagem HOST-CROSS (LFS=$LFS, LFS_TGT=$LFS_TGT)"

    check_versions_host_cross
    check_lfs_layout "$LFS"

    run_dummy_test "$LFS_TGT-gcc" "$LFS" "Cross toolchain ($LFS_TGT-gcc)" || true
    check_specs_for_tools "$LFS_TGT-gcc" "$LFS_TGT-gcc"
}

check_final() {
    head "Checagem FINAL (dentro do chroot / sistema LFS final)"

    check_versions_final
    # aqui root_prefix vazio porque já estamos em "/"
    run_dummy_test gcc "" "Toolchain final (gcc)" || true
    check_specs_for_tools gcc "gcc final"
}

detect_mode_auto() {
    # Se LFS e LFS_TGT estiverem definidos e ferramentas cross existem → host-cross
    if [[ -n "${LFS:-}" && -n "${LFS_TGT:-}" ]] && command -v "$LFS_TGT-gcc" >/dev/null 2>&1; then
        echo "host-cross"
        return
    fi
    # Se gcc está presente e não há LFS_TGT definido → provavelmente final
    if command -v gcc >/dev/null 2>&1 && [[ -z "${LFS_TGT:-}" ]]; then
        echo "final"
        return
    fi
    # fallback: host-cross
    echo "host-cross"
}

########################################
# 6. Parsing de argumentos
########################################

usage() {
    cat <<EOF
Uso: $(basename "$0") <modo> [opções]

Modos:
  host-cross   - checa o cross toolchain (rodar no host, com LFS e LFS_TGT)
  final        - checa o toolchain final (rodar dentro do chroot)
  auto         - tenta detectar automaticamente

Opções:
  --strict     - trata qualquer WARN como erro (exit 1)
  --log ARQ    - grava saída completa em ARQ

Exemplos:
  # no host:
  export LFS=/mnt/lfs
  export LFS_TGT=\$(uname -m)-lfs-linux-gnu
  $(basename "$0") host-cross --strict --log /tmp/toolchain-host.log

  # dentro do chroot:
  $(basename "$0") final
EOF
}

parse_args() {
    local arg
    while [[ $# -gt 0 ]]; do
        arg="$1"; shift
        case "$arg" in
            host-cross|final|auto)
                MODE="$arg"
                ;;
            --strict)
                STRICT=1
                ;;
            --log)
                LOG_FILE="${1:-}"
                shift || true
                if [[ -z "$LOG_FILE" ]]; then
                    echo "ERRO: --log precisa de um caminho." >&2
                    exit 1
                fi
                : >"$LOG_FILE" || {
                    echo "ERRO: não consegui criar $LOG_FILE" >&2
                    exit 1
                }
                ;;
            -h|--help|help)
                usage
                exit 0
                ;;
            *)
                echo "ERRO: argumento desconhecido: $arg" >&2
                usage
                exit 1
                ;;
        esac
    done
}

########################################
# 7. Main
########################################

main() {
    parse_args "$@"

    if [[ -z "$MODE" ]]; then
        MODE="auto"
    fi

    if [[ "$MODE" == "auto" ]]; then
        MODE="$(detect_mode_auto)"
        info "Modo auto detectado: $MODE"
    fi

    case "$MODE" in
        host-cross)
            check_host_cross
            ;;
        final)
            check_final
            ;;
        *)
            echo "ERRO: modo desconhecido: $MODE" >&2
            usage
            exit 1
            ;;
    esac

    head "Resumo"

    info "WARNINGS: $WARN_COUNT"
    info "ERROS:    $ERROR_COUNT"

    if (( ERROR_COUNT > 0 )); then
        error "Checagem terminou com ERROS."
        exit 1
    fi

    if (( STRICT == 1 && WARN_COUNT > 0 )); then
        error "STRICT=1 e há WARNINGS → consideramos checagem falha."
        exit 1
    fi

    info "Toolchain parece consistente dentro dos parâmetros desta checagem."
    exit 0
}

main "$@"
