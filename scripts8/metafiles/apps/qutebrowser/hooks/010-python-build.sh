#!/usr/bin/env bash
# Constrói via PEP 517 (wheel) e instala com pip, respeitando DESTDIR/PREFIX
set -Eeuo pipefail

: "${PREFIX:=/usr}"
: "${DESTDIR:=/}"

export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

# Preferir Qt6/PyQt6
export QT_SELECT="${QT_SELECT:-qt6}"

# Profile aggressive -> otimizações (só afetam extensões nativas, se houver)
if [[ "${ADM_PROFILE:-}" == "aggressive" ]]; then
  export CFLAGS="${CFLAGS:-} -O3 -pipe -fno-plt -march=native -mtune=native"
  export CXXFLAGS="${CXXFLAGS:-} -O3 -pipe -fno-plt -march=native -mtune=native"
fi

# Gera wheel (isolado) e instala em PREFIX respeitando DESTDIR
python3 -m pip wheel --no-deps --no-build-isolation -w dist .
python3 -m pip install --no-deps --no-warn-script-location \
  --prefix="${PREFIX}" --root="${DESTDIR}" dist/*.whl

echo "[qutebrowser] build+install via pip/PEP517 concluídos."
