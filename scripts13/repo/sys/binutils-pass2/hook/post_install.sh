#!/usr/bin/env bash
# post_install: binutils pass 2
# - strip agressivo de binários e libs da própria binutils
# - não falha caso strip não esteja disponível

set -euo pipefail

: "${ADM_INSTALL_ROOT:="/"}"

if ! command -v strip >/dev/null 2>&1; then
    echo "[binutils-pass2/post_install] 'strip' não encontrado, pulando strip agressivo."
    exit 0
fi

# Lista de binários principais da binutils
BIN_DIR="${ADM_INSTALL_ROOT%/}/usr/bin"

TARGET_BINS=(
  "ld"
  "ld.gold"
  "as"
  "objdump"
  "objcopy"
  "readelf"
  "nm"
  "addr2line"
  "ar"
  "ranlib"
)

echo "[binutils-pass2/post_install] Aplicando strip agressivo em binutils..."

for b in "${TARGET_BINS[@]}"; do
    if [[ -x "${BIN_DIR}/${b}" ]]; then
        echo "  strip --strip-unneeded ${BIN_DIR}/${b}"
        strip --strip-unneeded "${BIN_DIR}/${b}" 2>/dev/null || true
    fi
done

echo "[binutils-pass2/post_install] Strip concluído."
