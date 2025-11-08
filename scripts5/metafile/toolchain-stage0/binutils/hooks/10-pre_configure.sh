#!/usr/bin/env sh
# Prepara árvore de build fora da árvore de fontes

set -eu

: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"

# Cria diretório de build out-of-tree
mkdir -p "$BUILD_DIR" || true

# Pequena checagem de ferramentas do host
need() { command -v "$1" >/dev/null 2>&1 || { echo "Falta ferramenta: $1" >&2; exit 1; }; }
for t in bash awk sed make tar xz; do need "$t"; done

# Desabilita recursos que atrapalham em stage0
export CONFIGURE_DISABLES="--disable-nls --disable-werror --disable-gprofng --disable-static"

# Plugins ajudam na cadeia (ld/collect2)
export CONFIGURE_ENABLES="--enable-plugins"

# Honra sysroot/target
: "${TARGET:?TARGET não definido}"
: "${SYSROOT:?SYSROOT não definido}"
export CONFIGURE_SYSROOT="--with-sysroot=${SYSROOT}"
export CONFIGURE_TARGET="--target=${TARGET}"

# PREFIX/DESTDIR já devem vir do pipeline; aqui só garantimos
: "${PREFIX:?PREFIX não definido}"
: "${DESTDIR:?DESTDIR não definido}"

# Em stage0 não testamos por padrão (opcional no post_build)
: "${ADM_RUN_TESTS:=0}"
export ADM_RUN_TESTS
