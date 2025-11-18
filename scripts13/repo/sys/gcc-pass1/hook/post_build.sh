#!/usr/bin/env bash
# post_build: gcc pass 1
# - faz um sanity-check de compilação cruzada simples

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"

cd "${ADM_BUILD_DIR}/build"

MARKER=".sanity-done"
if [[ -f "${MARKER}" ]]; then
    echo "[gcc-pass1/post_build] Sanity-check já executado, pulando."
    exit 0
fi

default_target="$(uname -m)-lfs-linux-gnu"
TARGET="${ADM_TARGET:-${LFS_TGT:-$default_target}}"

echo "[gcc-pass1/post_build] Sanity-check de cross-compile (target=${TARGET})."

cat > dummy.c <<'EOF'
int main(void) { return 0; }
EOF

if make all-gcc >/dev/null 2>&1; then
    :
fi

if "${TARGET}-gcc" -o dummy dummy.c >/dev/null 2>&1; then
    echo "[gcc-pass1/post_build] Cross-compiler '${TARGET}-gcc' compilou dummy.c com sucesso."
else
    echo "[gcc-pass1/post_build] AVISO: '${TARGET}-gcc' falhou ao compilar dummy.c."
fi

rm -f dummy.c dummy 2>/dev/null || true
touch "${MARKER}"
