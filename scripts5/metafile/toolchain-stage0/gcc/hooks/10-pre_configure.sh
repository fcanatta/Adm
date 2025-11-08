#!/usr/bin/env sh
# Prepara build out-of-tree e "vende" gmp/mpfr/mpc para dentro de gcc/

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Falta $1" >&2; exit 1; }; }
for t in awk sed make tar xz; do need "$t"; done

mkdir -p "$BUILD_DIR" || true

cd "$SRC_DIR"

# Detecta tarballs de gmp/mpfr/mpc na árvore de fontes extraída (o seu pipeline extrai tudo em SRC_DIR)
# e faz o esquema "in-tree" esperado pelo GCC (diretórios 'gmp', 'mpfr', 'mpc').
link_one(){
  pkg="$1"
  set +e
  d="$(find "$SRC_DIR" -maxdepth 1 -type d -name "${pkg}-*" 2>/dev/null | head -n1)"
  set -e
  [ -n "$d" ] || { echo "[WARN] não achei $pkg-* em $SRC_DIR; assumindo já presente ou usando sistema (não recomendado)" >&2; return 0; }
  [ -e "$SRC_DIR/$pkg" ] || ln -s "$(basename "$d")" "$SRC_DIR/$pkg"
}
for p in gmp mpfr mpc; do link_one "$p"; done

# Pequena limpeza padrão recomendada
find . -name config.cache -delete 2>/dev/null || true
