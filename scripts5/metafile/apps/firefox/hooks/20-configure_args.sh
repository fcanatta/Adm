#!/usr/bin/env sh
# Gera .mozconfig em $BUILD_DIR e imprime uma linha em branco (mach usa .mozconfig)

set -eu

: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${PREFIX:?PREFIX não definido}"

MOZ="$BUILD_DIR/.mozconfig"

# Toolkit e build base
cat >"$MOZ" <<EOF
# Gerado pelo ADM
ac_add_options --prefix=${PREFIX}
ac_add_options --enable-release
ac_add_options --disable-debug
ac_add_options --disable-tests
ac_add_options --enable-strip
ac_add_options --enable-install-strip
ac_add_options --enable-application=browser
ac_add_options --enable-default-toolkit=cairo-gtk3
ac_add_options --with-branding=${ADM_FIREFOX_BRANDING}
EOF

# Preferir libs de sistema (adequar à sua base disponível)
cat >>"$MOZ" <<'EOF'
ac_add_options --with-system-zlib
ac_add_options --with-system-zstd
ac_add_options --with-system-png
ac_add_options --with-system-jpeg
ac_add_options --with-system-webp
ac_add_options --with-system-libvpx
ac_add_options --with-system-icu
ac_add_options --with-system-nspr
ac_add_options --with-system-nss
ac_add_options --with-system-libevent
EOF

# Linker
if [ -n "${MOZ_LD:-}" ]; then
  echo "ac_add_options --enable-linker=${MOZ_LD}" >>"$MOZ"
fi

# Flags de build
{
  echo "mk_add_options MOZ_MAKE_FLAGS=\"${MAKEFLAGS}\""
  echo "export CC=\"${CC}\""
  echo "export CXX=\"${CXX}\""
  [ -n "${CFLAGS:-}" ]   && echo "export CFLAGS=\"${CFLAGS}\""
  [ -n "${CXXFLAGS:-}" ] && echo "export CXXFLAGS=\"${CXXFLAGS}\""
  [ -n "${LDFLAGS:-}" ]  && echo "export LDFLAGS=\"${LDFLAGS}\""
} >>"$MOZ"

# Extras fornecidos pelo usuário
[ -n "${ADM_FIREFOX_MOZCONFIG_EXTRA}" ] && printf "%s\n" "${ADM_FIREFOX_MOZCONFIG_EXTRA}" >>"$MOZ"

# Para o pipeline: não passamos nada por stdout (mach lê .mozconfig)
echo ""
