#!/usr/bin/env bash
# 11-build-base-world.sh
# Atalhos de alto nível:
#   11-build-base-world.sh base  [opções]
#   11-build-base-world.sh world [opções]
#
# Opções:
#   --root <path>
#   --profile <minimal|normal|aggressive>
#   --libc <glibc|musl>

set -euo pipefail

if [[ -z "${ADM_ENV_LOADED:-}" ]]; then
    if [[ -f /usr/src/adm/scripts/01-env.sh ]]; then
        # shellcheck disable=SC1091
        . /usr/src/adm/scripts/01-env.sh
    else
        echo "ERRO: 01-env.sh não encontrado." >&2
        exit 1
    fi
fi

if [[ -z "${ADM_LIB_LOADED:-}" ]]; then
    if [[ -f /usr/src/adm/scripts/02-lib.sh ]]; then
        # shellcheck disable=SC1091
        . /usr/src/adm/scripts/02-lib.sh
    else
        echo "ERRO: 02-lib.sh não encontrado." >&2
        exit 1
    fi
fi

: "${ADM_SCRIPTS:=/usr/src/adm/scripts}"

if [[ ! -x "${ADM_SCRIPTS}/06-cross-toolchain.sh" ]]; then
    echo "ERRO: 06-cross-toolchain.sh não é executável." >&2
    exit 1
fi

cmd="$1"; shift || true

ROOT_OPT=()
PROFILE_OPT=()
LIBC_OPT=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            ROOT_OPT=(--root "$2")
            shift 2
            ;;
        --profile)
            PROFILE_OPT=(--profile "$2")
            shift 2
            ;;
        --libc)
            LIBC_OPT=(--libc "$2")
            shift 2
            ;;
        *)
            echo "Argumento desconhecido: $1" >&2
            exit 1
            ;;
    esac
done

case "$cmd" in
    base)
        "${ADM_SCRIPTS}/06-cross-toolchain.sh" base "${ROOT_OPT[@]}" "${PROFILE_OPT[@]}" "${LIBC_OPT[@]}"
        ;;
    world)
        "${ADM_SCRIPTS}/06-cross-toolchain.sh" world "${ROOT_OPT[@]}" "${PROFILE_OPT[@]}" "${LIBC_OPT[@]}"
        ;;
    *)
        cat <<EOF
Uso: 11-build-base-world.sh <base|world> [--root PATH] [--profile minimal|normal|aggressive] [--libc glibc|musl]

Exemplos:
  11-build-base-world.sh base  --root /mnt/lfs --profile minimal   --libc glibc
  11-build-base-world.sh world --root /mnt/lfs --profile aggressive --libc musl
EOF
        exit 1
        ;;
esac
