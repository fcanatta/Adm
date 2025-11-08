#!/usr/bin/env sh
# Prepara diretório de build (objdir) e checa dependências principais

set -eu

: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Falta ferramenta: $1" >&2; exit 1; }; }

for t in "$PYTHON" $CC $CXX awk sed make tar xz pkg-config; do need "$t"; done
for t in rustc cargo; do need "$t"; done
for t in $NODEJS yasm nasm; do need "$t"; done

# Objdir (out-of-tree)
mkdir -p "$BUILD_DIR" || true

# Checagem básica de crates vendorizados (os tarballs oficiais já incluem vendor/)
if [ ! -d "$SRC_DIR/third_party/rust" ]; then
  echo "[WARN] rust vendor não encontrado; o build pode tentar rede (bloqueado)" >&2
fi
