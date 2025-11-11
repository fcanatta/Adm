#!/usr/bin/env bash
set -Eeuo pipefail

# Se profile agressivo estiver ativo, reforçar flags
if [[ "${ADM_PROFILE:-}" == "aggressive" ]]; then
    export KCFLAGS="${KCFLAGS:-} -O3 -march=native -mtune=native -pipe -fno-plt"
    export KCPPFLAGS="${KCFLAGS}"
    export KLDFLAGS="${KLDFLAGS:-}"

    echo "[kernel performance] aggressive: KCFLAGS=${KCFLAGS}"
fi
