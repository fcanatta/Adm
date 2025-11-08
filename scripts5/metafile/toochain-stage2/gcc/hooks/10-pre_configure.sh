#!/usr/bin/env sh
# Prepara build out-of-tree e faz vendor opcional de gmp/mpfr/mpc/isl

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${ADM_GCC_VENDOR_LIBS:=1}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Falta $1" >&2; exit 1; }; }
for t in awk sed make tar xz; do need "$t"; done

mkdir -p "$BUILD_DIR" || true
cd "$SRC_DIR"

vendor_one(){
  pkg="$1"
  set +e
  d="$(find "$SRC_DIR" -maxdepth 1 -type d -name "${pkg}-*" 2>/dev/null | head -n1)"
  set -e
  [ -n "$d" ] || { echo "[WARN] não achei $pkg-*; assumindo libs do sistema" >&2; return 0; }
  [ -e "$SRC_DIR/$pkg" ] || ln -s "$(basename "$d")" "$SRC_DIR/$pkg"
}

if [ "${ADM_GCC_VENDOR_LIBS}" -eq 1 ]; then
  for p in gmp mpfr mpc isl; do vendor_one "$p"; done
fi

# Limpeza de caches
find . -name config.cache -delete 2>/dev/null || true
