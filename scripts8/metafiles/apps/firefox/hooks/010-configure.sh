#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

: "${PREFIX:=/usr}"
: "${SYSROOT:=/}"

export MOZBUILD_STATE_PATH="${PWD}/.mozbuild"

# aggressive profile → otimizações
if [[ "${ADM_PROFILE:-}" == "aggressive" ]]; then
  export CFLAGS="${CFLAGS:-} -O3 -march=native -pipe"
  export CXXFLAGS="${CXXFLAGS:-} -O3 -march=native -pipe"
fi

cat > .mozconfig <<EOF
ac_add_options --prefix=${PREFIX}
ac_add_options --enable-release
ac_add_options --enable-lto
ac_add_options --enable-optimize
ac_add_options --with-system-zlib
ac_add_options --with-system-icu
ac_add_options --with-system-nss
ac_add_options --disable-debug
ac_add_options --disable-tests
mk_add_options MOZ_OBJDIR=obj
EOF

echo "[FIREFOX] .mozconfig criado"
