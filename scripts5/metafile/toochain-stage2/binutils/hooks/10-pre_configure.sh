#!/usr/bin/env sh
# Prepara build out-of-tree e checa ferramentas

set -eu

: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${PREFIX:?PREFIX não definido}"

mkdir -p "$BUILD_DIR" || true

need() { command -v "$1" >/dev/null 2>&1 || { echo "Falta ferramenta: $1" >&2; exit 1; }; }
for t in bash awk sed make tar xz; do need "$t"; done

# Flags padrão de configuração para stage2 (nativo em /usr)
CFG_COMMON="--prefix=${PREFIX} --enable-shared --enable-plugins --disable-werror --with-system-zlib --with-pic --enable-deterministic-archives"
# 64-bit bfd para x86_64 (e congêneres que suportam 64)
case "$(uname -m 2>/dev/null || echo)" in
  x86_64|aarch64|ppc64le|s390x|riscv64) CFG_COMMON="$CFG_COMMON --enable-64-bit-bfd";;
esac

# gprofng costuma conflitar com musl; desabilite se pedido
[ "${ADM_BINUTILS_DISABLE_GPROFNG:-0}" -eq 1 ] && CFG_COMMON="$CFG_COMMON --disable-gprofng"

# gold opcional
if [ "${ADM_BINUTILS_ENABLE_GOLD:-0}" -eq 1 ]; then
  CFG_COMMON="$CFG_COMMON --enable-gold --enable-ld=default"
fi

export CONFIGURE_COMMON="$CFG_COMMON"
