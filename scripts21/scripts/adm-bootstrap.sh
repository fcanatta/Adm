#!/usr/bin/env bash
#
# adm-bootstrap.sh
#
# Orquestra o bootstrap completo do toolchain dentro de um ROOTFS do ADM:
#   pass1  -> toolchain temporário (binutils-pass1, gcc-pass1) em /tools
#   glibc  -> linux-api-headers + Glibc final
#   pass2  -> libs do GCC + binutils final + gcc final em /usr
#   final  -> limpeza de /tools e sanity-checks básicos
#
# Requisitos:
#   - adm.sh funcionando
#   - perfis do ADM (ex: glibc.profile) definindo ROOTFS, CHOST, ADM_JOBS
#   - scripts de pacote:
#       core/linux-api-headers
#       core/binutils-pass1
#       core/gcc-pass1
#       core/glibc
#       core/zlib
#       core/gmp
#       core/mpfr
#       core/mpc
#       core/binutils
#       core/gcc
#
# Uso:
#   ./adm-bootstrap.sh [opções] <fase>
#
# Fases:
#   pass1   - só binutils-pass1 + gcc-pass1
#   glibc   - linux-api-headers + glibc final
#   pass2   - zlib, gmp, mpfr, mpc, binutils final, gcc final
#   final   - limpeza /tools e sanity-checks
#   all     - tudo na ordem: pass1 -> glibc -> pass2 -> final
#
# Exemplo:
#   ADM_PROFILE=glibc ./adm-bootstrap.sh all
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuráveis
# ---------------------------------------------------------------------------

# Caminho do adm.sh
ADM_SH="${ADM_SH:-/opt/adm/adm.sh}"

# Nome do profile (definido fora ou usa glibc por padrão)
ADM_PROFILE="${ADM_PROFILE:-glibc}"

# Onde ficam os profiles
ADM_PROFILE_DIR="${ADM_PROFILE_DIR:-/opt/adm/profiles}"

# Verbose (0 ou 1)
BOOTSTRAP_VERBOSE="${BOOTSTRAP_VERBOSE:-1}"

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

log() {
    local level="$1"; shift
    printf '[%s] %s\n' "$level" "$*" >&2
}

die() {
    log "ERRO" "$*"
    exit 1
}

run_adm() {
    local cmd="$1"; shift
    local pkg="$1"; shift || true

    if [[ "$BOOTSTRAP_VERBOSE" == "1" ]]; then
        log "ADM" "$ADM_SH $cmd $pkg $*"
    fi

    "$ADM_SH" "$cmd" "$pkg" "$@"
}

load_profile() {
    local pf="${ADM_PROFILE_DIR}/${ADM_PROFILE}.profile"
    [[ -f "$pf" ]] || die "Profile não encontrado: $pf (ajuste ADM_PROFILE_DIR ou ADM_PROFILE)."

    # shellcheck source=/dev/null
    . "$pf"

    : "${ROOTFS:?ROOTFS não definido pelo profile ${ADM_PROFILE}.profile}"
    : "${CHOST:?CHOST não definido pelo profile ${ADM_PROFILE}.profile}"

    log "INFO" "Profile carregado: $ADM_PROFILE (ROOTFS=$ROOTFS, CHOST=$CHOST)"
}

usage() {
    cat <<EOF
Uso: $(basename "$0") [opções] <fase>

Fases:
  pass1   - binutils-pass1 + gcc-pass1 (toolchain temporário em /tools)
  glibc   - linux-api-headers + Glibc final
  pass2   - zlib, gmp, mpfr, mpc, binutils final, gcc final
  final   - limpeza de /tools e sanity-checks básicos
  all     - executa todas as fases na ordem: pass1 -> glibc -> pass2 -> final

Opções:
  ADM_SH=/caminho/para/adm.sh         (padrão: /opt/adm/adm.sh)
  ADM_PROFILE=glibc|musl|...          (padrão: glibc)
  ADM_PROFILE_DIR=/opt/adm/profiles   (padrão: /opt/adm/profiles)
  BOOTSTRAP_VERBOSE=0|1               (padrão: 1)

Exemplos:
  ADM_PROFILE=glibc ./adm-bootstrap.sh all
  ADM_PROFILE=glibc ./adm-bootstrap.sh pass1
EOF
}

# ---------------------------------------------------------------------------
# Fases
# ---------------------------------------------------------------------------

phase_pass1() {
    log "INFO" "=== FASE PASS1: toolchain temporário em /tools ==="

    # Aqui assumo que linux-api-headers será instalado na fase glibc,
    # pra manter a semântica de headers "definitivos". Se você quiser,
    # pode puxar core/linux-api-headers pra cá.

    # Binutils pass1 (prefix=/tools dentro do ROOTFS)
    run_adm build   core/binutils-pass1
    run_adm install core/binutils-pass1

    # GCC pass1 (prefix=/tools dentro do ROOTFS)
    run_adm build   core/gcc-pass1
    run_adm install core/gcc-pass1

    log "INFO" "=== PASS1 concluída ==="
}

phase_glibc() {
    log "INFO" "=== FASE GLIBC: headers + Glibc final ==="

    # Linux API headers (definitivos) em $ROOTFS/usr/include
    run_adm build   core/linux-api-headers
    run_adm install core/linux-api-headers

    # Glibc final em /usr do ROOTFS
    run_adm build   core/glibc
    run_adm install core/glibc

    log "INFO" "=== GLIBC concluída ==="
}

phase_pass2() {
    log "INFO" "=== FASE PASS2: libs do GCC + binutils/gcc finais ==="

    # Bibliotecas de suporte ao GCC (ordem importante por dependência)
    run_adm build   core/zlib
    run_adm install core/zlib

    run_adm build   core/gmp
    run_adm install core/gmp

    run_adm build   core/mpfr
    run_adm install core/mpfr

    run_adm build   core/mpc
    run_adm install core/mpc

    # Binutils final em /usr
    run_adm build   core/binutils
    run_adm install core/binutils

    # GCC final em /usr
    run_adm build   core/gcc
    run_adm install core/gcc

    log "INFO" "=== PASS2 concluída ==="
}

phase_final() {
    log "INFO" "=== FASE FINAL: limpeza e sanity-checks ==="

    # Limpa /tools dentro do ROOTFS (toolchain temporário)
    if [[ -d "$ROOTFS/tools" ]]; then
        log "INFO" "Removendo toolchain temporário em $ROOTFS/tools"
        rm -rf "$ROOTFS/tools"
    else
        log "INFO" "$ROOTFS/tools não existe (já limpo)."
    fi

    # Opcional: se existir ldconfig no ROOTFS, roda ele via chroot
    if [[ -x "$ROOTFS/sbin/ldconfig" ]]; then
        log "INFO" "Executando ldconfig dentro do ROOTFS"
        chroot "$ROOTFS" /sbin/ldconfig || log "WARN" "ldconfig dentro do ROOTFS falhou (verifique manualmente)."
    fi

    log "INFO" "=== Bootstrap do toolchain concluído ==="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    local phase="$1"
    shift || true

    [[ -x "$ADM_SH" ]] || die "adm.sh não encontrado ou não executável: $ADM_SH"

    load_profile

    case "$phase" in
        pass1)
            phase_pass1
            ;;
        glibc)
            phase_glibc
            ;;
        pass2)
            phase_pass2
            ;;
        final)
            phase_final
            ;;
        all)
            phase_pass1
            phase_glibc
            phase_pass2
            phase_final
            ;;
        *)
            usage
            die "Fase desconhecida: $phase"
            ;;
    esac
}

main "$@"
