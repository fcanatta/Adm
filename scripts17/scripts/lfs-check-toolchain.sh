#!/usr/bin/env bash
#
# lfs-check-toolchain
# -------------------
# Script de checagem do toolchain LFS.
#
# Modos:
#   host-cross  → checa o cross toolchain ($LFS_TGT-gcc, binutils, glibc no $LFS)
#   final       → checa toolchain final (dentro do chroot, usando gcc normal)
#
# Uso:
#   # no host, com LFS e LFS_TGT exportados
#   LFS=/mnt/lfs LFS_TGT=$(uname -m)-lfs-linux-gnu lfs-check-toolchain host-cross
#
#   # dentro do chroot (já em /), usando gcc normal
#   lfs-check-toolchain final
#

set -euo pipefail

MODE="${1:-}"

color() {
    local code="$1"; shift
    if [[ -t 1 ]]; then
        printf "\033[%sm%s\033[0m" "$code" "$*"
    else
        printf "%s" "$*"
    fi
}

info()  { echo "$(color '1;32' '[INFO]')  $*"; }
warn()  { echo "$(color '1;33' '[WARN]')  $*"; }
error() { echo "$(color '1;31' '[ERRO]')  $*" >&2; }

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
# 1. Checagem do cross toolchain (host)
########################################
check_host_cross() {
    : "${LFS:?VARIÁVEL LFS não definida}"
    : "${LFS_TGT:?VARIÁVEL LFS_TGT não definida}"

    info "Checando cross toolchain para target: $LFS_TGT"
    check_cmd "$LFS_TGT-gcc" "$LFS_TGT-ld" "$LFS_TGT-as" readelf grep sed

    # 1) Onde estão os programas?
    info "Localização dos principais binários:"
    command -v "$LFS_TGT-gcc"
    command -v "$LFS_TGT-ld"
    command -v "$LFS_TGT-as"

    # 2) Dummy test igual ao LFS
    tmpdir="$(mktemp -d /tmp/lfs-toolchain-check.XXXXXX)"
    trap 'rm -rf "$tmpdir"' EXIT

    cat >"$tmpdir/dummy.c" << "EOF"
int main(void) { return 0; }
EOF

    info "Compilando dummy.c com $LFS_TGT-gcc..."
    "$LFS_TGT-gcc" "$tmpdir/dummy.c" -v -Wl,--verbose -o "$tmpdir/a.out" &> "$tmpdir/dummy.log"

    info "Lendo program interpreter com readelf..."
    readelf -l "$tmpdir/a.out" | grep ': /lib' || warn "Nenhuma linha com ': /lib' encontrada (confira manualmente)."

    info "Verificando start files (crt*.o)..."
    grep -E -o "$LFS/lib.*/S?crt[1in].*succeeded" "$tmpdir/dummy.log" || \
        warn "Não encontrei linhas de start files 'crt[1in]'."

    info "Verificando diretório de includes padrão..."
    grep -B4 "^ $LFS/usr/include" "$tmpdir/dummy.log" || \
        warn "Não achei entrada clara de includes em $LFS/usr/include."

    info "Verificando caminhos de busca do linker..."
    grep 'SEARCH.*/usr/lib' "$tmpdir/dummy.log" | sed 's/; /\n/g' || \
        warn "Não achei SEARCH_DIR para /usr/lib no dummy.log."

    info "Verificando libc em $LFS..."
    grep "/lib.*/libc.so.6 " "$tmpdir/dummy.log" || \
        warn "Não vi referência a libc.so.6 no dummy.log."

    info "Verificando dynamic linker..."
    grep 'found' "$tmpdir/dummy.log" || \
        warn "Não vi linha 'found' para o dynamic linker no dummy.log."

    # 3) Verificar se NÃO há /tools nos specs
    info "Checando se specs do gcc ainda mencionam /tools..."
    "$LFS_TGT-gcc" -dumpspecs > "$tmpdir/specs"
    if grep -q '/tools' "$tmpdir/specs"; then
        warn "Foram encontradas referências a /tools nos specs do $LFS_TGT-gcc."
        warn "Depois de ajustar o toolchain final, isso deve desaparecer."
    else
        info "Nenhuma referência a /tools nos specs do $LFS_TGT-gcc."
    fi

    info "Checagem do cross toolchain concluída."
}

########################################
# 2. Checagem do toolchain final
#    (deve ser rodada dentro do chroot)
########################################
check_final() {
    info "Checando toolchain final (gcc do sistema atual)."
    check_cmd gcc ld as readelf grep sed

    tmpdir="$(mktemp -d /tmp/lfs-toolchain-check.XXXXXX)"
    trap 'rm -rf "$tmpdir"' EXIT

    cat >"$tmpdir/dummy.c" << "EOF"
int main(void) { return 0; }
EOF

    info "Compilando dummy.c com gcc..."
    gcc "$tmpdir/dummy.c" -v -Wl,--verbose -o "$tmpdir/a.out" &> "$tmpdir/dummy.log"

    info "Lendo program interpreter com readelf..."
    readelf -l "$tmpdir/a.out" | grep ': /lib' || warn "Nenhuma linha com ': /lib' encontrada (confira manualmente)."

    info "Verificando start files (crt*.o)..."
    grep -E -o '/usr/lib.*/S?crt[1in].*succeeded' "$tmpdir/dummy.log" || \
        warn "Não encontrei linhas de start files 'crt[1in]'."

    info "Verificando diretório de includes padrão..."
    grep -B4 '^ /usr/include' "$tmpdir/dummy.log" || \
        warn "Não achei entrada clara de includes em /usr/include."

    info "Verificando caminhos de busca do linker..."
    grep 'SEARCH.*/usr/lib' "$tmpdir/dummy.log" | sed 's/; /\n/g' || \
        warn "Não achei SEARCH_DIR para /usr/lib no dummy.log."

    info "Verificando libc do sistema..."
    grep "/lib.*/libc.so.6 " "$tmpdir/dummy.log" || \
        warn "Não vi referência a libc.so.6 no dummy.log."

    info "Verificando dynamic linker..."
    grep 'found' "$tmpdir/dummy.log" || \
        warn "Não vi linha 'found' para o dynamic linker no dummy.log."

    info "Checando se specs do gcc ainda mencionam /tools..."
    gcc -dumpspecs > "$tmpdir/specs"
    if grep -q '/tools' "$tmpdir/specs"; then
        warn "Foram encontradas referências a /tools nos specs do gcc final."
        warn "Isso indica que o ajuste de specs ainda não foi feito ou está incorreto."
    else
        info "Nenhuma referência a /tools nos specs do gcc final."
    fi

    info "Checagem do toolchain final concluída."
}

########################################
# 3. Main
########################################

usage() {
    cat <<EOF
Uso: $(basename "$0") <modo>

Modos:
  host-cross   - checa o cross toolchain (rodar no host, com LFS e LFS_TGT exportados)
  final        - checa o toolchain final (rodar dentro do chroot do LFS)

Exemplos:
  # no host:
  export LFS=/mnt/lfs
  export LFS_TGT=\$(uname -m)-lfs-linux-gnu
  $(basename "$0") host-cross

  # dentro do chroot:
  $(basename "$0") final
EOF
}

case "$MODE" in
  host-cross)
    check_host_cross
    ;;
  final)
    check_final
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    error "Modo desconhecido: $MODE"
    usage
    exit 1
    ;;
esac
