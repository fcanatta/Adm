#!/usr/bin/env sh
# Gera .mozconfig conforme LTO/PGO, libs do sistema e linker

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${PREFIX:?PREFIX não definido}"

MOZ="$BUILD_DIR/.mozconfig"

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
# libs de sistema
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
[ -n "${MOZ_LD:-}" ] && echo "ac_add_options --enable-linker=${MOZ_LD}" >>"$MOZ"

# LTO
case "${ADM_FIREFOX_LTO:-}" in
  thin) echo "ac_add_options --enable-lto=thin" >>"$MOZ";;
  full) echo "ac_add_options --enable-lto" >>"$MOZ";;
  *) :;;
esac

# PGO (fase final usa --enable-profile-use; a fase 1 (generate) é injetada no hook 40)
# Aqui não ativamos ainda; só na fase 2.

# Flags
{
  echo "mk_add_options MOZ_MAKE_FLAGS=\"${MAKEFLAGS}\""
  echo "export CC=\"${CC}\""
  echo "export CXX=\"${CXX}\""
  [ -n "${CFLAGS:-}" ]   && echo "export CFLAGS=\"${CFLAGS}\""
  [ -n "${CXXFLAGS:-}" ] && echo "export CXXFLAGS=\"${CXXFLAGS}\""
  [ -n "${LDFLAGS:-}" ]  && echo "export LDFLAGS=\"${LDFLAGS}\""
} >>"$MOZ"

# Extras do usuário
[ -n "${ADM_FIREFOX_MOZCONFIG_EXTRA}" ] && printf "%s\n" "${ADM_FIREFOX_MOZCONFIG_EXTRA}" >>"$MOZ"

# Link em SRC_DIR para compatibilidade
[ -f "$SRC_DIR/.mozconfig" ] || ln -s "$MOZ" "$SRC_DIR/.mozconfig" 2>/dev/null || true

# Nada a emitir por stdout
echo ""
