#!/usr/bin/env bash
# 08-adm-build-system-helpers.part1.sh
# Helpers padronizados para múltiplos sistemas de build (configure→build→test→install),
# fixups (rpath/strip/compress/docs), integração com hooks & patches e perfis.
# Requer: 00-adm-config.sh, 01-adm-lib.sh, 04-adm-metafile.sh, 05-adm-hooks-patches.sh
###############################################################################
# Guardas e pré-requisitos
###############################################################################
if [[ -n "${ADM_BS_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_BS_LOADED_PART1=1

if [[ -z "${ADM_CONF_LOADED:-}" ]]; then
  echo "ERRO: build-system-helpers requer 00-adm-config.sh carregado." >&2
  return 2 2>/dev/null || exit 2
fi
if [[ -z "${ADM_LIB_LOADED:-}" ]]; then
  echo "ERRO: build-system-helpers requer 01-adm-lib.sh carregado." >&2
  return 2 2>/dev/null || exit 2
fi

###############################################################################
# Defaults de política (podem ser sobrescritos em 00-adm-config.sh)
###############################################################################
: "${ADM_JOBS:=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"
: "${ADM_RUN_TESTS:=false}"
: "${ADM_STRIP:=true}"
: "${ADM_DEBUG_SPLIT:=false}"
: "${ADM_LTO:=false}"
: "${ADM_HARDEN:=true}"
: "${ADM_OFFLINE:=false}"
: "${ADM_TIMEOUT_CONFIGURE:=3600}"
: "${ADM_TIMEOUT_BUILD:=14400}"
: "${ADM_TIMEOUT_TEST:=7200}"
: "${ADM_TIMEOUT_INSTALL:=3600}"
: "${ADM_REMOVE_LA:=true}"

: "${ADM_BUILD_ROOT:=/usr/src/adm/build}"
: "${ADM_DEST_ROOT:=/usr/src/adm/dest}"
: "${ADM_STATE_ROOT:=/usr/src/adm/state}"
: "${ADM_DOC_DIR:=/usr/share/doc}"
: "${ADM_LICENSE_DIR:=/usr/share/licenses}"

###############################################################################
# Utilidades internas
###############################################################################
bs_err()  { adm_err "$*"; }
bs_warn() { adm_warn "$*"; }
bs_info() { adm_log INFO "${PKG_NAME:-pkg}" "helpers" "$*"; }

bs_require_cmd() {
  local c; for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { bs_err "comando obrigatório ausente: $c"; return 2; }
  done
}

bs_in_path_under() {
  # bs_in_path_under <path> <root> → 0 se path está sob root
  local p="$(readlink -f -- "$1" 2>/dev/null || realpath -s "$1" 2>/dev/null || echo "$1")"
  local r="$(readlink -f -- "$2" 2>/dev/null || realpath -s "$2" 2>/dev/null || echo "$2")"
  [[ "$p" == "$r"* ]]
}

bs_dest_required() {
  [[ -n "${DESTDIR:-}" ]] || { bs_err "DESTDIR não definido"; return 5; }
  [[ "$DESTDIR" != "/" ]] || { bs_err "DESTDIR não pode ser '/'"; return 5; }
}

adm_bs_destdir_sanity_check() {
  bs_dest_required || return $?
  mkdir -p -- "$DESTDIR" || { bs_err "falha ao criar DESTDIR: $DESTDIR"; return 3; }
  bs_in_path_under "$DESTDIR" "/" || { bs_err "DESTDIR inválido: $DESTDIR"; return 5; }
}

adm_bs_libdir_auto() {
  local force="${ADM_LIBDIR_FORCE:-}"
  [[ -n "$force" ]] && { echo "$force"; return 0; }
  local ma
  ma="$(gcc -print-multiarch 2>/dev/null || true)"
  if [[ -n "$ma" ]]; then
    echo "lib/$ma"; return 0
  fi
  local bits
  bits="$(getconf LONG_BIT 2>/dev/null || echo 64)"
  if [[ "$bits" = "64" ]]; then
    echo "lib64"
  else
    echo "lib"
  fi
}

adm_bs_prepare_dirs() {
  [[ -n "${PKG_CATEGORY:-}" && -n "${PKG_NAME:-}" && -n "${PKG_VERSION:-}" ]] || {
    bs_err "prepare_dirs: PKG_{CATEGORY,NAME,VERSION} ausentes"; return 2; }
  [[ -d "${SRC_DIR:-}" ]] || { bs_err "prepare_dirs: SRC_DIR inválido: ${SRC_DIR:-<vazio>}"; return 3; }
  : "${BUILD_DIR:=${ADM_BUILD_ROOT%/}/${PKG_CATEGORY}/${PKG_NAME}-${PKG_VERSION}}"
  : "${DESTDIR:=${ADM_DEST_ROOT%/}/${PKG_CATEGORY}/${PKG_NAME}/${PKG_VERSION}}"
  mkdir -p -- "$BUILD_DIR" "$DESTDIR" || { bs_err "falha ao criar BUILD_DIR/DESTDIR"; return 3; }
  adm_bs_destdir_sanity_check || return $?
  bs_info "BUILD_DIR=$BUILD_DIR DESTDIR=$DESTDIR"
}

adm_bs_export_env() {
  local profile="${PROFILE:-${ADM_PROFILE_DEFAULT:-normal}}"
  local cc_default="$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || command -v clang 2>/dev/null || echo cc)"
  local cxx_default="$(command -v c++ 2>/dev/null || command -v g++ 2>/dev/null || command -v clang++ 2>/dev/null || echo c++)"

  : "${CC:=$cc_default}"
  : "${CXX:=$cxx_default}"

  case "$profile" in
    minimal)
      CFLAGS="${CFLAGS:-"-O0 -g -pipe -fno-plt"}"
      CXXFLAGS="${CXXFLAGS:-"-O0 -g -pipe -fno-plt"}"
      FFLAGS="${FFLAGS:-"-O0 -g"}"
      LDFLAGS="${LDFLAGS:-"-Wl,--as-needed,-O1"}"
      ;;
    aggressive)
      CFLAGS="${CFLAGS:-"-O3 -pipe -march=native"}"
      CXXFLAGS="${CXXFLAGS:-"-O3 -pipe -march=native"}"
      FFLAGS="${FFLAGS:-"-O3"}"
      LDFLAGS="${LDFLAGS:-"-Wl,--as-needed,-O1"}"
      [[ "$ADM_LTO" == "true" ]] && { CFLAGS="$CFLAGS -flto"; CXXFLAGS="$CXXFLAGS -flto"; LDFLAGS="$LDFLAGS -flto"; }
      ;;
    normal|*)
      CFLAGS="${CFLAGS:-"-O2 -g -pipe -fwrapv"}"
      CXXFLAGS="${CXXFLAGS:-"-O2 -g -pipe -fwrapv"}"
      FFLAGS="${FFLAGS:-"-O2 -g"}"
      LDFLAGS="${LDFLAGS:-"-Wl,--as-needed,-O1"}"
      [[ "$ADM_LTO" == "true" ]] && { CFLAGS="$CFLAGS -flto"; CXXFLAGS="$CXXFLAGS -flto"; LDFLAGS="$LDFLAGS -flto"; }
      ;;
  esac

  if [[ "$ADM_HARDEN" == "true" ]]; then
    CFLAGS="$CFLAGS -D_FORTIFY_SOURCE=3 -fstack-protector-strong"
    CXXFLAGS="$CXXFLAGS -D_FORTIFY_SOURCE=3 -fstack-protector-strong"
    # PIE/RELRO/NOW (ignoradas se não suportadas)
    LDFLAGS="$LDFLAGS -Wl,-z,relro,-z,now"
  fi

  export CC CXX FFLAGS CFLAGS CXXFLAGS LDFLAGS
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-$LANG}"
  export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date -u +%s)}"
  export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/share/pkgconfig:/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
  bs_info "ambiente exportado (profile=${profile})"
}

adm_bs_prefix_args() {
  local libdir="$(adm_bs_libdir_auto)"
  printf -- "--prefix=/usr --sysconfdir=/etc --localstatedir=/var --libdir=/usr/%s" "$libdir"
}

adm_bs_jobs() {
  local n="${JOBS:-$ADM_JOBS}"
  echo "$n"
}

###############################################################################
# Testes, strip/compress, rpath, pkg-config fixups, docs/licenças/manifest
###############################################################################
adm_bs_run_tests_generic() {
  local cmd=("$@")
  [[ "$ADM_RUN_TESTS" == "true" ]] || { bs_info "testes desabilitados (ADM_RUN_TESTS=false)"; return 0; }
  bs_require_cmd timeout || return 2
  adm_with_spinner "Executando testes..." -- timeout "$ADM_TIMEOUT_TEST" "${cmd[@]}" || {
    bs_err "testes falharam: ${cmd[*]}"; return 4; }
  adm_ok "testes concluídos"
}

adm_bs_strip_and_compress() {
  bs_dest_required || return $?
  local did_strip="no"
  if [[ "$ADM_STRIP" == "true" ]]; then
    if command -v strip >/dev/null 2>&1; then
      # strip bin/libs
      mapfile -t bins < <(find "$DESTDIR" -type f -perm -0100 -print 2>/dev/null)
      mapfile -t libs < <(find "$DESTDIR" -type f \( -name "*.so*" -o -name "*.dylib" \) -print 2>/dev/null)
      local f
      for f in "${bins[@]}" "${libs[@]}"; do
        [[ -f "$f" ]] || continue
        strip -s "$f" >/dev/null 2>&1 && did_strip="yes" || true
      done
    fi
  fi
  # compress man/info
  mapfile -t mans < <(find "$DESTDIR/usr/share/man" -type f -name "*.[0-9]" 2>/dev/null || true)
  local m; for m in "${mans[@]}"; do gzip -n -9 "$m" 2>/dev/null || true; done
  bs_info "strip=${did_strip}"
}

adm_bs_fix_rpath() {
  bs_dest_required || return $?
  local p
  if command -v patchelf >/dev/null 2>&1; then
    mapfile -t p < <(find "$DESTDIR" -type f -exec file {} \; | awk -F: '/ELF/ {print $1}')
    local f; for f in "${p[@]}"; do
      # limpar RPATH perigoso (com DESTDIR embutido)
      local r; r="$(patchelf --print-rpath "$f" 2>/dev/null || true)"
      [[ -z "$r" ]] && continue
      if grep -q "$DESTDIR" <<<"$r"; then
        patchelf --remove-rpath "$f" 2>/dev/null || true
      fi
    done
  elif command -v chrpath >/dev/null 2>&1; then
    mapfile -t p < <(find "$DESTDIR" -type f -exec file {} \; | awk -F: '/ELF/ {print $1}')
    local f; for f in "${p[@]}"; do
      chrpath -d "$f" >/dev/null 2>&1 || true
    done
  else
    bs_warn "patchelf/chrpath não encontrado — pulando fix de rpath"
  fi
}

adm_bs_pkgconfig_fixups() {
  bs_dest_required || return $?
  local pc
  mapfile -t pc < <(find "$DESTDIR/usr" -type f -name "*.pc" 2>/dev/null || true)
  local libdir="$(adm_bs_libdir_auto)"
  local f; for f in "${pc[@]}"; do
    sed -i -E "s|^prefix=.*$|prefix=/usr|g" "$f" 2>/dev/null || true
    sed -i -E "s|^libdir=.*$|libdir=/usr/${libdir}|g" "$f" 2>/dev/null || true
    sed -i -E "s|${DESTDIR}||g" "$f" 2>/dev/null || true
  done
}

adm_bs_install_docs_and_licenses() {
  bs_dest_required || return $?
  local dstdoc="${DESTDIR}${ADM_DOC_DIR%/}/${PKG_NAME}"
  local dstlic="${DESTDIR}${ADM_LICENSE_DIR%/}/${PKG_NAME}"
  mkdir -p -- "$dstdoc" "$dstlic" 2>/dev/null || true
  local f
  for f in LICENSE* COPYING* README*; do
    if compgen -G "${SRC_DIR%/}/$f" >/dev/null; then
      cp -a "${SRC_DIR%/}"/$f "$dstlic"/ 2>/dev/null || cp -a "${SRC_DIR%/}"/$f "$dstdoc"/ 2>/dev/null || true
    fi
  done
}

adm_bs_manifest_write() {
  bs_dest_required || return $?
  local manroot="${ADM_STATE_ROOT%/}/manifest"
  mkdir -p -- "$manroot" 2>/dev/null || true
  local outf="${manroot}/${PKG_CATEGORY}_${PKG_NAME}_${PKG_VERSION}.list"
  : > "$outf" || { bs_warn "não foi possível criar manifest: $outf"; return 3; }
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$DESTDIR" && find . -type f -print0 | xargs -0 sha256sum) >> "$outf" 2>/dev/null || true
  else
    (cd "$DESTDIR" && find . -type f -print) >> "$outf" 2>/dev/null || true
  fi
  echo "$outf"
}

adm_bs_triggers_record() {
  bs_dest_required || return $?
  local trgroot="${ADM_STATE_ROOT%/}/triggers"
  mkdir -p -- "$trgroot" || true
  local t="${trgroot}/${PKG_CATEGORY}_${PKG_NAME}_${PKG_VERSION}.trg"
  : > "$t" || { bs_warn "não foi possível criar triggers: $t"; return 3; }
  # Exemplos: o orquestrador do instalador final decide quando rodar
  if compgen -G "${DESTDIR}/usr/share/glib-2.0/schemas/*.xml" >/dev/null; then
    echo "glib-compile-schemas /usr/share/glib-2.0/schemas" >> "$t"
  fi
  if compgen -G "${DESTDIR}/usr/share/icons/*/index.theme" >/dev/null; then
    echo "gtk-update-icon-cache" >> "$t"
  fi
  if compgen -G "${DESTDIR}/usr/share/applications/*.desktop" >/dev/null; then
    echo "update-desktop-database" >> "$t"
  fi
  echo "$t"
}

adm_bs_shebang_rewrite() {
  # Normaliza shebangs para /usr/bin/env quando aplicável
  bs_dest_required || return $?
  local files
  mapfile -t files < <(find "$DESTDIR" -type f -perm -0100 -print 2>/dev/null || true)
  local f; for f in "${files[@]}"; do
    head -c 2 "$f" 2>/dev/null | grep -q '^#!' || continue
    sed -n '1p' "$f" | grep -Eq '^#! */(usr/)?bin/(python|python3|bash|sh|env|node|perl|ruby)' || continue
    perl -0777 -pe 'BEGIN{$^I="";} s|^#! */usr/bin/python3|#!/usr/bin/env python3|;
                    s|^#! */usr/bin/python|#!/usr/bin/env python|;
                    s|^#! */bin/bash|#!/usr/bin/env bash|;
                    s|^#! */bin/sh|#!/usr/bin/env sh|;
                    s|^#! */usr/bin/node|#!/usr/bin/env node|;
                    s|^#! */usr/bin/perl|#!/usr/bin/env perl|;
                    s|^#! */usr/bin/ruby|#!/usr/bin/env ruby|;' \
      -i "$f" 2>/dev/null || true
  done
}
# 08-adm-build-system-helpers.part2.sh
# Helpers por sistema de build: Autotools, CMake, Meson, Make, Cargo, Go, Python, Node, Java, .NET.
if [[ -n "${ADM_BS_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_BS_LOADED_PART2=1
###############################################################################
# Autotools
###############################################################################
adm_bs_autotools_configure() {
  adm_bs_prepare_dirs || return $?
  adm_bs_export_env || return $?
  adm_hooks_run pre-prepare || return $?
  adm_patches_apply "$SRC_DIR" || return $?
  adm_hooks_run post-prepare || return $?

  pushd "$SRC_DIR" >/dev/null || { bs_err "pushd SRC_DIR falhou"; return 3; }
  if [[ ! -x "./configure" ]]; then
    bs_info "configure ausente — rodando autoreconf -fi"
    bs_require_cmd autoreconf || { popd >/dev/null; return 2; }
    autoreconf -fi || { popd >/dev/null; bs_err "autoreconf falhou"; return 4; }
  fi
  local prefix; prefix="$(adm_bs_prefix_args)"
  local hostopt=()
  [[ -n "${CHOST:-}" ]] && hostopt+=( "--host=$CHOST" "--build=$(gcc -dumpmachine 2>/dev/null || echo unknown)" )
  adm_hooks_run pre-configure || { popd >/dev/null; return 4; }
  adm_with_spinner "Configurando (autotools)..." -- timeout "$ADM_TIMEOUT_CONFIGURE" ./configure $prefix --disable-static "${hostopt[@]}" || {
    popd >/dev/null; bs_err "./configure falhou"; return 4; }
  adm_hooks_run post-configure || { popd >/dev/null; return 4; }
  popd >/dev/null
  return 0
}

adm_bs_autotools_build() {
  adm_hooks_run pre-build || return $?
  local j; j="$(adm_bs_jobs)"
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" make -j"$j" ) || { bs_err "make falhou"; return 4; }
  adm_hooks_run post-build || return 4
  return 0
}

adm_bs_autotools_test() {
  [[ "$ADM_RUN_TESTS" == "true" ]] || { bs_info "testes desabilitados"; return 0; }
  adm_hooks_run pre-test || return $?
  ( cd "$SRC_DIR" && adm_bs_run_tests_generic make check ) || return $?
  adm_hooks_run post-test || return 4
  return 0
}

adm_bs_autotools_install() {
  adm_hooks_run pre-install || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_INSTALL" make install DESTDIR="$DESTDIR" ) || { bs_err "make install falhou"; return 4; }
  [[ "$ADM_REMOVE_LA" == "true" ]] && find "$DESTDIR" -type f -name "*.la" -delete 2>/dev/null || true
  adm_bs_pkgconfig_fixups
  adm_bs_fix_rpath
  adm_bs_strip_and_compress
  adm_bs_install_docs_and_licenses
  adm_bs_shebang_rewrite
  adm_hooks_run post-install || return 4
  adm_bs_manifest_write >/dev/null 2>&1 || true
  adm_bs_triggers_record >/dev/null 2>&1 || true
  return 0
}

###############################################################################
# CMake (+ Ninja)
###############################################################################
adm_bs_cmake_configure() {
  adm_bs_prepare_dirs || return $?
  adm_bs_export_env || return $?
  adm_hooks_run pre-prepare || return $?
  adm_patches_apply "$SRC_DIR" || return $?
  adm_hooks_run post-prepare || return $?

  bs_require_cmd cmake || return 2
  local libdir; libdir="$(adm_bs_libdir_auto)"
  local args=(
    -S "$SRC_DIR" -B "$BUILD_DIR" -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX=/usr
    -DCMAKE_INSTALL_LIBDIR="$libdir"
    -DBUILD_SHARED_LIBS=ON
    -DCMAKE_SKIP_RPATH=OFF
  )
  [[ -n "${CMAKE_TOOLCHAIN_FILE:-}" ]] && args+=( "-DCMAKE_TOOLCHAIN_FILE=$CMAKE_TOOLCHAIN_FILE" )
  adm_hooks_run pre-configure || return 4
  adm_with_spinner "Configurando (CMake)..." -- timeout "$ADM_TIMEOUT_CONFIGURE" cmake "${args[@]}" || {
    bs_err "cmake configure falhou"; return 4; }
  adm_hooks_run post-configure || return 4
  return 0
}

adm_bs_cmake_build() {
  bs_require_cmd cmake || return 2
  adm_hooks_run pre-build || return $?
  local j; j="$(adm_bs_jobs)"
  adm_with_spinner "Compilando (CMake)..." -- timeout "$ADM_TIMEOUT_BUILD" cmake --build "$BUILD_DIR" -j"$j" || {
    bs_err "cmake --build falhou"; return 4; }
  adm_hooks_run post-build || return 4
  return 0
}

adm_bs_cmake_test() {
  [[ "$ADM_RUN_TESTS" == "true" ]] || { bs_info "testes desabilitados"; return 0; }
  bs_require_cmd ctest || return 2
  adm_hooks_run pre-test || return $?
  adm_bs_run_tests_generic ctest --test-dir "$BUILD_DIR" --output-on-failure || return $?
  adm_hooks_run post-test || return 4
  return 0
}

adm_bs_cmake_install() {
  bs_require_cmd cmake || return 2
  adm_hooks_run pre-install || return $?
  adm_with_spinner "Instalando (CMake)..." -- timeout "$ADM_TIMEOUT_INSTALL" cmake --install "$BUILD_DIR" --prefix /usr || {
    bs_err "cmake --install falhou"; return 4; }
  adm_bs_pkgconfig_fixups
  adm_bs_fix_rpath
  adm_bs_strip_and_compress
  adm_bs_install_docs_and_licenses
  adm_bs_shebang_rewrite
  adm_hooks_run post-install || return 4
  adm_bs_manifest_write >/dev/null 2>&1 || true
  adm_bs_triggers_record >/dev/null 2>&1 || true
  return 0
}

###############################################################################
# Meson (+ Ninja)
###############################################################################
adm_bs_meson_setup() {
  adm_bs_prepare_dirs || return $?
  adm_bs_export_env || return $?
  adm_hooks_run pre-prepare || return $?
  adm_patches_apply "$SRC_DIR" || return $?
  adm_hooks_run post-prepare || return $?

  bs_require_cmd meson ninja || return 2
  local libdir; libdir="$(adm_bs_libdir_auto)"
  local args=(
    setup "$BUILD_DIR" "$SRC_DIR"
    --prefix=/usr --libdir="$libdir" --buildtype=release
    -Ddefault_library=shared -Db_pie=true
  )
  [[ "$ADM_LTO" == "true" ]] && args+=( "-Db_lto=true" )
  [[ -n "${MESON_CROSS_FILE:-}" ]] && args+=( "--cross-file=$MESON_CROSS_FILE" )
  adm_hooks_run pre-configure || return 4
  adm_with_spinner "Configurando (Meson)..." -- timeout "$ADM_TIMEOUT_CONFIGURE" meson "${args[@]}" || {
    bs_err "meson setup falhou"; return 4; }
  adm_hooks_run post-configure || return 4
  return 0
}

adm_bs_meson_build() {
  bs_require_cmd meson || return 2
  adm_hooks_run pre-build || return $?
  local j; j="$(adm_bs_jobs)"
  adm_with_spinner "Compilando (Meson)..." -- timeout "$ADM_TIMEOUT_BUILD" meson compile -C "$BUILD_DIR" -j "$j" || {
    bs_err "meson compile falhou"; return 4; }
  adm_hooks_run post-build || return 4
  return 0
}

adm_bs_meson_test() {
  [[ "$ADM_RUN_TESTS" == "true" ]] || { bs_info "testes desabilitados"; return 0; }
  bs_require_cmd meson || return 2
  adm_hooks_run pre-test || return $?
  adm_bs_run_tests_generic meson test -C "$BUILD_DIR" --no-rebuild --print-errorlogs || return $?
  adm_hooks_run post-test || return 4
  return 0
}

adm_bs_meson_install() {
  bs_require_cmd meson || return 2
  adm_hooks_run pre-install || return $?
  adm_with_spinner "Instalando (Meson)..." -- timeout "$ADM_TIMEOUT_INSTALL" meson install -C "$BUILD_DIR" --destdir "$DESTDIR" || {
    bs_err "meson install falhou"; return 4; }
  [[ "$ADM_REMOVE_LA" == "true" ]] && find "$DESTDIR" -type f -name "*.la" -delete 2>/dev/null || true
  adm_bs_pkgconfig_fixups
  adm_bs_fix_rpath
  adm_bs_strip_and_compress
  adm_bs_install_docs_and_licenses
  adm_bs_shebang_rewrite
  adm_hooks_run post-install || return 4
  adm_bs_manifest_write >/dev/null 2>&1 || true
  adm_bs_triggers_record >/dev/null 2>&1 || true
  return 0
}

###############################################################################
# Make “puro”
###############################################################################
adm_bs_make_build() {
  adm_bs_prepare_dirs || return $?
  adm_bs_export_env || return $?
  adm_hooks_run pre-build || return $?
  local j; j="$(adm_bs_jobs)"
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" make -j"$j" ) || { bs_err "make falhou"; return 4; }
  adm_hooks_run post-build || return 4
}

adm_bs_make_test() {
  [[ "$ADM_RUN_TESTS" == "true" ]] || { bs_info "testes desabilitados"; return 0; }
  adm_hooks_run pre-test || return $?
  ( cd "$SRC_DIR" && { make -q test 2>/dev/null || make -q check 2>/dev/null; } ) || {
    bs_warn "alvo de teste ausente — pulando"; return 0; }
  ( cd "$SRC_DIR" && adm_bs_run_tests_generic make test ) || ( cd "$SRC_DIR" && adm_bs_run_tests_generic make check ) || return $?
  adm_hooks_run post-test || return 4
}

adm_bs_make_install() {
  adm_hooks_run pre-install || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_INSTALL" make install DESTDIR="$DESTDIR" PREFIX=/usr ) || { bs_err "make install falhou"; return 4; }
  [[ "$ADM_REMOVE_LA" == "true" ]] && find "$DESTDIR" -type f -name "*.la" -delete 2>/dev/null || true
  adm_bs_pkgconfig_fixups
  adm_bs_fix_rpath
  adm_bs_strip_and_compress
  adm_bs_install_docs_and_licenses
  adm_bs_shebang_rewrite
  adm_hooks_run post-install || return 4
  adm_bs_manifest_write >/dev/null 2>&1 || true
  adm_bs_triggers_record >/dev/null 2>&1 || true
}

###############################################################################
# Cargo (Rust)
###############################################################################
adm_bs_cargo_build() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd cargo || return 2
  [[ "$ADM_OFFLINE" == "true" ]] && set -- "$@" --frozen --locked
  adm_hooks_run pre-build || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" cargo build --release "$@" ) || { bs_err "cargo build falhou"; return 4; }
  adm_hooks_run post-build || return 4
}

adm_bs_cargo_test() {
  [[ "$ADM_RUN_TESTS" == "true" ]] || { bs_info "testes desabilitados"; return 0; }
  bs_require_cmd cargo || return 2
  [[ "$ADM_OFFLINE" == "true" ]] && set -- "$@" --frozen --locked
  adm_hooks_run pre-test || return $?
  ( cd "$SRC_DIR" && adm_bs_run_tests_generic cargo test --release "$@" ) || return $?
  adm_hooks_run post-test || return 4
}

adm_bs_cargo_install() {
  bs_require_cmd cargo || return 2
  adm_hooks_run pre-install || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_INSTALL" cargo install --path "$SRC_DIR" --root "$DESTDIR/usr" ) || { bs_err "cargo install falhou"; return 4; }
  adm_bs_strip_and_compress
  adm_bs_install_docs_and_licenses
  adm_bs_shebang_rewrite
  adm_hooks_run post-install || return 4
  adm_bs_manifest_write >/dev/null 2>&1 || true
  adm_bs_triggers_record >/devnull 2>&1 || true
}

###############################################################################
# Go (modules)
###############################################################################
adm_bs_go_build() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd go || return 2
  local envs=()
  [[ -d "$SRC_DIR/vendor" ]] && envs+=( "GOFLAGS=-mod=vendor" )
  [[ "$ADM_OFFLINE" == "true" ]] && envs+=( "GOPROXY=off" )
  adm_hooks_run pre-build || return $?
  ( cd "$SRC_DIR" && env "${envs[@]}" timeout "$ADM_TIMEOUT_BUILD" go build -trimpath ./... ) || { bs_err "go build falhou"; return 4; }
  adm_hooks_run post-build || return 4
}

adm_bs_go_test() {
  [[ "$ADM_RUN_TESTS" == "true" ]] || { bs_info "testes desabilitados"; return 0; }
  bs_require_cmd go || return 2
  local envs=()
  [[ -d "$SRC_DIR/vendor" ]] && envs+=( "GOFLAGS=-mod=vendor" )
  [[ "$ADM_OFFLINE" == "true" ]] && envs+=( "GOPROXY=off" )
  adm_hooks_run pre-test || return $?
  ( cd "$SRC_DIR" && env "${envs[@]}" adm_bs_run_tests_generic go test ./... -count=1 ) || return $?
  adm_hooks_run post-test || return 4
}

adm_bs_go_install() {
  bs_require_cmd go || return 2
  adm_hooks_run pre-install || return $?
  ( cd "$SRC_DIR" && GOBIN="$DESTDIR/usr/bin" timeout "$ADM_TIMEOUT_INSTALL" go install ./... ) || { bs_err "go install falhou"; return 4; }
  adm_bs_strip_and_compress
  adm_bs_install_docs_and_licenses
  adm_bs_shebang_rewrite
  adm_hooks_run post-install || return 4
  adm_bs_manifest_write >/dev/null 2>&1 || true
  adm_bs_triggers_record >/dev/null 2>&1 || true
}

###############################################################################
# Python (PEP 517)
###############################################################################
adm_bs_python_build() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd python3 || return 2
  local have_build=0
  command -v python3 -m build >/dev/null 2>&1 && have_build=1 || true
  adm_hooks_run pre-build || return $?
  if (( have_build==1 )); then
    ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" python3 -m build --wheel --no-isolation ) || { bs_err "python build falhou"; return 4; }
  else
    bs_require_cmd pip || return 2
    ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" pip wheel -w dist . ) || { bs_err "pip wheel falhou"; return 4; }
  fi
  adm_hooks_run post-build || return 4
}

adm_bs_python_test() {
  [[ "$ADM_RUN_TESTS" == "true" ]] || { bs_info "testes desabilitados"; return 0; }
  adm_hooks_run pre-test || return $?
  if compgen -G "$SRC_DIR/pytest.ini" >/dev/null || grep -R -q "pytest" "$SRC_DIR" 2>/dev/null; then
    adm_bs_run_tests_generic python3 -m pytest -q -k "not slow" -p no:faulthandler -p no:cacheprovider || return $?
  elif grep -R -q "unittest" "$SRC_DIR" 2>/dev/null; then
    adm_bs_run_tests_generic python3 -m unittest discover -v || return $?
  else
    bs_warn "nenhuma suíte de testes detectada (pytest/unittest) — pulando"
  fi
  adm_hooks_run post-test || return 4
}

adm_bs_python_install() {
  bs_require_cmd pip || return 2
  adm_hooks_run pre-install || return $?
  local wheel
  wheel="$(ls -1 "$SRC_DIR"/dist/*.whl 2>/dev/null | head -n1 || true)"
  if [[ -z "$wheel" ]]; then
    bs_err "wheel não encontrado em dist/ — rode adm_bs_python_build antes"; return 3;
  fi
  local extra=()
  if [[ "$ADM_OFFLINE" == "true" ]]; then
    extra+=( "--no-index" )
    [[ -n "${ADM_PY_CACHE:-}" && -d "$ADM_PY_CACHE" ]] && extra+=( "--find-links" "$ADM_PY_CACHE" )
  fi
  timeout "$ADM_TIMEOUT_INSTALL" pip install --no-deps --root "$DESTDIR" --prefix /usr "${extra[@]}" "$wheel" || {
    bs_err "pip install falhou"; return 4; }
  adm_bs_strip_and_compress
  adm_bs_install_docs_and_licenses
  adm_bs_shebang_rewrite
  adm_hooks_run post-install || return 4
  adm_bs_manifest_write >/dev/null 2>&1 || true
  adm_bs_triggers_record >/dev/null 2>&1 || true
}

###############################################################################
# Node (npm/yarn/pnpm)
###############################################################################
adm_bs_node_ci() {
  adm_bs_prepare_dirs || return $?
  local mgr=""
  if [[ -f "$SRC_DIR/package-lock.json" ]]; then mgr="npm"; elif [[ -f "$SRC_DIR/yarn.lock" ]]; then mgr="yarn"; elif [[ -f "$SRC_DIR/pnpm-lock.yaml" ]]; then mgr="pnpm"; fi
  [[ -n "$mgr" ]] || { bs_err "nenhum lockfile encontrado (npm/yarn/pnpm)"; return 3; }
  adm_hooks_run pre-build || return $?
  case "$mgr" in
    npm)  [[ "$ADM_OFFLINE" == "true" ]] && npm config set offline true >/dev/null 2>&1 || true; timeout "$ADM_TIMEOUT_BUILD" npm ci --prefix "$SRC_DIR" || { bs_err "npm ci falhou"; return 4; } ;;
    yarn) timeout "$ADM_TIMEOUT_BUILD" yarn --cwd "$SRC_DIR" install --frozen-lockfile || { bs_err "yarn install falhou"; return 4; } ;;
    pnpm) timeout "$ADM_TIMEOUT_BUILD" pnpm i --dir "$SRC_DIR" --frozen-lockfile || { bs_err "pnpm i falhou"; return 4; } ;;
  esac
  adm_hooks_run post-build || return 4
}

adm_bs_node_build() {
  local pkg="$SRC_DIR/package.json"
  [[ -f "$pkg" ]] || { bs_err "package.json não encontrado"; return 3; }
  if grep -q '"build"' "$pkg"; then
    ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" npm run build ) || { bs_err "npm run build falhou"; return 4; }
  else
    bs_info "script build não encontrado — pulando"
  fi
}

adm_bs_node_install() {
  local name
  name="$(jq -r '.name' "$SRC_DIR/package.json" 2>/dev/null || echo "$PKG_NAME")"
  [[ -n "$name" ]] || name="$PKG_NAME"
  local target="$DESTDIR/usr/lib/node_modules/$name"
  mkdir -p -- "$target" "$DESTDIR/usr/bin" || { bs_err "falha ao criar diretórios node"; return 3; }
  rsync -a --exclude node_modules --exclude .git "$SRC_DIR"/ "$target"/ 2>/dev/null || cp -a "$SRC_DIR"/. "$target"/
  # wrapper CLI se "bin" existir
  local bin_cmd
  bin_cmd="$(jq -r '.bin // empty | (if type=="object" then to_entries[0].value else . end)' "$SRC_DIR/package.json" 2>/dev/null || true)"
  if [[ -n "$bin_cmd" ]]; then
    cat > "$DESTDIR/usr/bin/$name" <<EOF
#!/usr/bin/env sh
exec node "/usr/lib/node_modules/$name/$bin_cmd" "\$@"
EOF
    chmod +x "$DESTDIR/usr/bin/$name"
  fi
  adm_bs_strip_and_compress
  adm_bs_install_docs_and_licenses
  adm_bs_shebang_rewrite
  adm_bs_manifest_write >/dev/null 2>&1 || true
  adm_bs_triggers_record >/dev/null 2>&1 || true
}

###############################################################################
# Java (Maven/Gradle)
###############################################################################
adm_bs_maven_build() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd mvn || return 2
  local args=( -DskipTests )
  [[ "$ADM_RUN_TESTS" == "true" ]] && args=( )
  [[ "$ADM_OFFLINE" == "true" ]] && args+=( -o )
  adm_hooks_run pre-build || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" mvn -B -V clean package "${args[@]}" ) || { bs_err "maven build falhou"; return 4; }
  adm_hooks_run post-build || return 4
}

adm_bs_gradle_build() {
  adm_bs_prepare_dirs || return $?
  local grad="gradle"; [[ -x "$SRC_DIR/gradlew" ]] && grad="$SRC_DIR/gradlew"
  bs_require_cmd "$grad" || return 2
  local args=( build -x test )
  [[ "$ADM_RUN_TESTS" == "true" ]] && args=( build )
  [[ "$ADM_OFFLINE" == "true" ]] && args+=( --offline )
  adm_hooks_run pre-build || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" "$grad" "${args[@]}" ) || { bs_err "gradle build falhou"; return 4; }
  adm_hooks_run post-build || return 4
}

adm_bs_java_install() {
  # Instala JARs em /usr/share/java/<name> e wrapper em /usr/bin
  local name="${PKG_NAME}"
  local dst="$DESTDIR/usr/share/java/$name"
  mkdir -p -- "$dst" "$DESTDIR/usr/bin" || { bs_err "falha ao criar diretórios java"; return 3; }
  find "$SRC_DIR" -type f -name "*.jar" -exec cp -a {} "$dst"/ \; 2>/dev/null || true
  cat > "$DESTDIR/usr/bin/$name" <<'EOF'
#!/usr/bin/env sh
exec java -jar "/usr/share/java/___NAME___/$(ls /usr/share/java/___NAME___/*.jar | head -n1)" "$@"
EOF
  sed -i "s/___NAME___/$name/g" "$DESTDIR/usr/bin/$name"
  chmod +x "$DESTDIR/usr/bin/$name"
  adm_bs_strip_and_compress
  adm_bs_install_docs_and_licenses
  adm_bs_manifest_write >/dev/null 2>&1 || true
  adm_bs_triggers_record >/dev/null 2>&1 || true
}

###############################################################################
# .NET
###############################################################################
adm_bs_dotnet_build() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd dotnet || return 2
  adm_hooks_run pre-build || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" dotnet restore --nologo && dotnet build -c Release --nologo ) || { bs_err "dotnet build falhou"; return 4; }
  adm_hooks_run post-build || return 4
}

adm_bs_dotnet_test() {
  [[ "$ADM_RUN_TESTS" == "true" ]] || { bs_info "testes desabilitados"; return 0; }
  bs_require_cmd dotnet || return 2
  adm_hooks_run pre-test || return $?
  ( cd "$SRC_DIR" && adm_bs_run_tests_generic dotnet test -c Release --nologo ) || return $?
  adm_hooks_run post-test || return 4
}

adm_bs_dotnet_install() {
  bs_require_cmd dotnet || return 2
  adm_hooks_run pre-install || return $?
  local out="$DESTDIR/usr/lib/$PKG_NAME"
  mkdir -p -- "$out" "$DESTDIR/usr/bin" || { bs_err "falha ao criar diretórios .NET"; return 3; }
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_INSTALL" dotnet publish -c Release --self-contained false -o "$out" ) || { bs_err "dotnet publish falhou"; return 4; }
  cat > "$DESTDIR/usr/bin/$PKG_NAME" <<EOF
#!/usr/bin/env sh
exec dotnet "/usr/lib/$PKG_NAME/$(ls "$out"/*.dll | head -n1 | xargs -n1 basename)" "\$@"
EOF
  chmod +x "$DESTDIR/usr/bin/$PKG_NAME"
  adm_bs_strip_and_compress
  adm_bs_install_docs_and_licenses
  adm_bs_manifest_write >/dev/null 2>&1 || true
  adm_bs_triggers_record >/dev/null 2>&1 || true
}
# 08-adm-build-system-helpers.part3.sh
# Helpers adicionais: Swift, Zig, Nim, Haskell, OCaml, Perl, Ruby, PHP/Composer, D/Dub, Custom.
if [[ -n "${ADM_BS_LOADED_PART3:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_BS_LOADED_PART3=1
###############################################################################
# Swift
###############################################################################
adm_bs_swift_build() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd swift || return 2
  adm_hooks_run pre-build || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" swift build -c release ) || { bs_err "swift build falhou"; return 4; }
  adm_hooks_run post-build || return 4
}
adm_bs_swift_install() {
  adm_hooks_run pre-install || return $?
  mkdir -p "$DESTDIR/usr/bin" || { bs_err "falha dirs swift"; return 3; }
  find "$SRC_DIR/.build" -type f -perm -0100 -maxdepth 2 -print 2>/dev/null | while read -r b; do
    cp -a "$b" "$DESTDIR/usr/bin/" || true
  done
  adm_bs_strip_and_compress
  adm_bs_manifest_write >/dev/null 2>&1 || true
}

###############################################################################
# Zig
###############################################################################
adm_bs_zig_build() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd zig || return 2
  adm_hooks_run pre-build || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" zig build -Drelease-safe=true ) || { bs_err "zig build falhou"; return 4; }
  adm_hooks_run post-build || return 4
}
adm_bs_zig_install() {
  adm_hooks_run pre-install || return $?
  mkdir -p "$DESTDIR/usr/bin" || { bs_err "falha dirs zig"; return 3; }
  if [[ -d "$SRC_DIR/zig-out/bin" ]]; then
    cp -a "$SRC_DIR/zig-out/bin/"* "$DESTDIR/usr/bin/" 2>/dev/null || true
  fi
  adm_bs_strip_and_compress
  adm_bs_manifest_write >/dev/null 2>&1 || true
}

###############################################################################
# Nim
###############################################################################
adm_bs_nim_build() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd nim || return 2
  adm_hooks_run pre-build || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" nim c -d:release -p:"$SRC_DIR" *.nim ) || { bs_err "nim build falhou"; return 4; }
  adm_hooks_run post-build || return 4
}
adm_bs_nim_install() {
  adm_hooks_run pre-install || return $?
  mkdir -p "$DESTDIR/usr/bin" || { bs_err "falha dirs nim"; return 3; }
  find "$SRC_DIR" -maxdepth 1 -type f -perm -0100 -print -exec cp -a {} "$DESTDIR/usr/bin/" \; 2>/dev/null || true
  adm_bs_strip_and_compress
  adm_bs_manifest_write >/dev/null 2>&1 || true
}

###############################################################################
# Haskell (Cabal)
###############################################################################
adm_bs_hs_build() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd cabal || return 2
  adm_hooks_run pre-build || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" cabal v2-update && cabal v2-build --enable-executable-dynamic ) || { bs_err "cabal build falhou"; return 4; }
  adm_hooks_run post-build || return 4
}
adm_bs_hs_install() {
  adm_hooks_run pre-install || return $?
  mkdir -p "$DESTDIR/usr/bin" || { bs_err "falha dirs hs"; return 3; }
  # copia binários da dist-newstyle se existirem
  find "$SRC_DIR/dist-newstyle" -type f -perm -0100 -name "*" -exec cp -a {} "$DESTDIR/usr/bin/" \; 2>/dev/null || true
  adm_bs_strip_and_compress
  adm_bs_manifest_write >/dev/null 2>&1 || true
}

###############################################################################
# OCaml (Dune)
###############################################################################
adm_bs_dune_build() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd dune || return 2
  adm_hooks_run pre-build || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" dune build ) || { bs_err "dune build falhou"; return 4; }
  adm_hooks_run post-build || return 4
}
adm_bs_dune_test() {
  [[ "$ADM_RUN_TESTS" == "true" ]] || { bs_info "testes desabilitados"; return 0; }
  bs_require_cmd dune || return 2
  adm_hooks_run pre-test || return $?
  ( cd "$SRC_DIR" && adm_bs_run_tests_generic dune runtest ) || return $?
  adm_hooks_run post-test || return 4
}
adm_bs_dune_install() {
  adm_hooks_run pre-install || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_INSTALL" dune install --destdir "$DESTDIR" ) || { bs_err "dune install falhou"; return 4; }
  adm_bs_strip_and_compress
  adm_bs_manifest_write >/dev/null 2>&1 || true
}

###############################################################################
# Perl
###############################################################################
adm_bs_perl_build_install() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd perl make || return 2
  adm_hooks_run pre-configure || return $?
  if [[ -f "$SRC_DIR/Makefile.PL" ]]; then
    ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_CONFIGURE" perl Makefile.PL PREFIX=/usr ) || { bs_err "perl Makefile.PL falhou"; return 4; }
    adm_hooks_run pre-build || return $?
    ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" make -j"$(adm_bs_jobs)" ) || { bs_err "perl make falhou"; return 4; }
    adm_hooks_run pre-install || return $?
    ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_INSTALL" make install DESTDIR="$DESTDIR" ) || { bs_err "perl make install falhou"; return 4; }
  elif [[ -f "$SRC_DIR/Build.PL" ]]; then
    bs_require_cmd ./Build || true
    ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_CONFIGURE" perl Build.PL ) || { bs_err "perl Build.PL falhou"; return 4; }
    ( cd "$SRC_DIR" && ./Build ) || { bs_err "perl Build falhou"; return 4; }
    ( cd "$SRC_DIR" && ./Build install --destdir "$DESTDIR" ) || { bs_err "perl Build install falhou"; return 4; }
  else
    bs_err "Perl: nem Makefile.PL nem Build.PL"; return 3;
  fi
  adm_bs_strip_and_compress
  adm_bs_manifest_write >/dev/null 2>&1 || true
}

###############################################################################
# Ruby (Gem)
###############################################################################
adm_bs_ruby_build_install() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd gem ruby || return 2
  adm_hooks_run pre-build || return $?
  ( cd "$SRC_DIR" && gem build *.gemspec ) || { bs_err "gem build falhou"; return 4; }
  local pkg; pkg="$(ls -1 "$SRC_DIR"/*.gem 2>/dev/null | head -n1 || true)"
  [[ -n "$pkg" ]] || { bs_err "gem não gerado"; return 3; }
  adm_hooks_run pre-install || return $?
  gem install --install-dir "$DESTDIR/usr/lib/ruby/gems" --no-document "$pkg" || { bs_err "gem install falhou"; return 4; }
  adm_bs_strip_and_compress
  adm_bs_manifest_write >/dev/null 2>&1 || true
}

###############################################################################
# PHP / Composer
###############################################################################
adm_bs_php_composer_install() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd composer php || return 2
  local args=( install --no-dev --no-interaction )
  [[ "$ADM_OFFLINE" == "true" ]] && args+=( --no-plugins --no-scripts ) # mínima rede
  adm_hooks_run pre-build || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" composer "${args[@]}" ) || { bs_err "composer install falhou"; return 4; }
  local dst="$DESTDIR/usr/share/$PKG_NAME"
  mkdir -p -- "$dst" || return 3
  rsync -a --exclude .git "$SRC_DIR"/ "$dst"/ 2>/dev/null || cp -a "$SRC_DIR"/. "$dst"/
  adm_bs_strip_and_compress
  adm_bs_manifest_write >/dev/null 2>&1 || true
}

###############################################################################
# D (Dub)
###############################################################################
adm_bs_dub_build() {
  adm_bs_prepare_dirs || return $?
  bs_require_cmd dub || return 2
  adm_hooks_run pre-build || return $?
  ( cd "$SRC_DIR" && timeout "$ADM_TIMEOUT_BUILD" dub build --build=release ) || { bs_err "dub build falhou"; return 4; }
  adm_hooks_run post-build || return 4
}
adm_bs_dub_install() {
  adm_hooks_run pre-install || return $?
  mkdir -p "$DESTDIR/usr/bin" || { bs_err "falha dirs dub"; return 3; }
  find "$SRC_DIR" -maxdepth 2 -type f -perm -0100 -print -exec cp -a {} "$DESTDIR/usr/bin/" \; 2>/dev/null || true
  adm_bs_strip_and_compress
  adm_bs_manifest_write >/dev/null 2>&1 || true
}

###############################################################################
# Custom (scripts do pacote)
###############################################################################
adm_bs_custom_run() {
  # Executa build customizado do pacote via hooks/scripts locais
  adm_bs_prepare_dirs || return $?
  adm_bs_export_env || return $?
  adm_hooks_run pre-configure || return $?
  adm_hooks_run configure || true
  adm_hooks_run post-configure || true

  adm_hooks_run pre-build || return $?
  adm_hooks_run build || return $?
  adm_hooks_run post-build || return $?

  [[ "$ADM_RUN_TESTS" == "true" ]] && { adm_hooks_run pre-test || return $?; adm_hooks_run test || true; adm_hooks_run post-test || true; }

  adm_hooks_run pre-install || return $?
  adm_hooks_run install || return $?
  adm_hooks_run post-install || return $?

  adm_bs_fix_rpath
  adm_bs_strip_and_compress
  adm_bs_install_docs_and_licenses
  adm_bs_shebang_rewrite
  adm_bs_manifest_write >/dev/null 2>&1 || true
  adm_bs_triggers_record >/dev/null 2>&1 || true
  return 0
}

###############################################################################
# Marcar como carregado
###############################################################################
ADM_BS_LOADED=1
export ADM_BS_LOADED
