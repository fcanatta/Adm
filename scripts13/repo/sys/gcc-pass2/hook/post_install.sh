#!/usr/bin/env bash
# post_install: gcc pass 2
# - garante symlink cc -> gcc
# - sanity-check: compila e (se possível) executa um binário simples

set -euo pipefail

: "${ADM_INSTALL_ROOT:="/"}"

BIN_DIR="${ADM_INSTALL_ROOT%/}/usr/bin"

if [[ -x "${BIN_DIR}/gcc" && ! -e "${BIN_DIR}/cc" ]]; then
    echo "[gcc-pass2/post_install] Criando symlink cc -> gcc."
    ln -sf gcc "${BIN_DIR}/cc"
else
    echo "[gcc-pass2/post_install] Symlink cc já existe ou gcc ausente."
fi

# Sanity-check: compilação + execução opcional
TMPDIR="${TMPDIR:-/tmp}"
WORK="${TMPDIR%/}/adm-gcc-pass2-sanity.$$"
mkdir -p "${WORK}"
cd "${WORK}"

cat > main.c <<'EOF'
#include <stdio.h>
int main(void) {
    printf("toolchain-ok\n");
    return 0;
}
EOF

if "${BIN_DIR}/gcc" -o main main.c >/dev/null 2>&1; then
    echo "[gcc-pass2/post_install] gcc compilou main.c com sucesso."
    # Executar só se estivermos em um chroot/sistema com /lib resolvido
    if ./main >/dev/null 2>&1; then
        echo "[gcc-pass2/post_install] Execução de ./main ok (toolchain funcional)."
    else
        echo "[gcc-pass2/post_install] AVISO: ./main não executou (provável problema de runtime/chroot)."
    fi
else
    echo "[gcc-pass2/post_install] AVISO: gcc falhou ao compilar main.c."
fi

cd /
rm -rf "${WORK}" 2>/dev/null || true
