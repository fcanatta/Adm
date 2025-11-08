# ADM Profile: musl-aggressive
# Objetivo: alvo *-musl com flags agressivas (O3, march=native, ThinLTO) e sysroot/target propagados.
# Preferência por Clang; se indisponível, tenta toolchain cross (${TARGET}-gcc).
# Ativação: adm --profile musl-aggressive

if [ -n "${_ADM_PROFILE_MUSL_AGGR:-}" ]; then return 0 2>/dev/null || exit 0; fi
_ADM_PROFILE_MUSL_AGGR=1

export PROFILE_NAME="musl-aggressive"
export PROFILE_VERSION="1.0"

# Triplet e sysroot (ajuste MUSL_TARGET/MUSL_SYSROOT antes do apply, se quiser)
: "${MUSL_TARGET:=x86_64-linux-musl}"
: "${MUSL_SYSROOT:=/}"

export TARGET="${TARGET:-${MUSL_TARGET}}"
export SYSROOT="${SYSROOT:-${MUSL_SYSROOT}}"

# Preferir PATH do ROOT quando usando --root
if [ -n "${ADM_EFFECTIVE_ROOT:-}" ] && [ -d "${ADM_EFFECTIVE_ROOT}/usr/bin" ]; then
  export PATH="${ADM_EFFECTIVE_ROOT}/usr/bin:${PATH}"
fi

# Preferir Clang como driver (com --target/--sysroot); fallback para cross gcc
if command -v clang >/dev/null 2>&1; then
  export CC="clang --target=${TARGET} --sysroot=${SYSROOT}"
  export CXX="clang++ --target=${TARGET} --sysroot=${SYSROOT}"
  export CPP="clang-cpp --target=${TARGET} --sysroot=${SYSROOT}"
else
  if command -v "${TARGET}-gcc" >/dev/null 2>&1; then
    export CC="${TARGET}-gcc --sysroot=${SYSROOT}"
    export CXX="${TARGET}-g++ --sysroot=${SYSROOT}"
  else
    # Fallback (pode exigir specs ajustados no gcc do host)
    command -v gcc >/dev/null 2>&1 && export CC="gcc --sysroot=${SYSROOT}"
    command -v g++ >/dev/null 2>&1 && export CXX="g++ --sysroot=${SYSROOT}"
  fi
fi

# Ferramentas LLVM (preferidas com musl)
command -v ld.lld >/dev/null 2>&1   && export LD="ld.lld"
command -v llvm-ar >/dev/null 2>&1  && export AR="llvm-ar"
command -v llvm-ranlib >/dev/null 2>&1 && export RANLIB="llvm-ranlib"
command -v llvm-nm >/dev/null 2>&1  && export NM="llvm-nm"
command -v llvm-strip >/dev/null 2>&1 && export STRIP="llvm-strip"

# Parâmetros agressivos
: "${AGGR_OPT_LEVEL:=O3}"
: "${AGGR_USE_OFAST:=0}"               # 1=Ofast (pode quebrar portabilidade/precisão)
: "${AGGR_MARCH:=native}"
: "${AGGR_MTUNE:=native}"
: "${AGGR_LTO:=thin}"                  # thin|full|off
: "${AGGR_USE_PIE:=1}"
: "${AGGR_FUSE_LLD:=1}"

_base_opt="-O3 -pipe"
[ "${AGGR_USE_OFAST}" = "1" ] && _base_opt="-Ofast -fno-math-errno -ffp-contract=fast -funsafe-math-optimizations -pipe"
_marchmtune=""
[ -n "${AGGR_MARCH}" ] && _marchmtune="${_marchmtune} -march=${AGGR_MARCH}"
[ -n "${AGGR_MTUNE}" ] && _marchmtune="${_marchmtune} -mtune=${AGGR_MTUNE}"

_lto=""
case "${AGGR_LTO}" in
  thin|Thin|THIN) _lto="-flto=thin";;
  full|FULL)      _lto="-flto";;
  off|OFF|0|"")   _lto="";;
esac

_pie_cc=""; _pie_ld=""
[ "${AGGR_USE_PIE}" = "1" ] && { _pie_cc="-fPIE"; _pie_ld="-pie"; }

_ldf="-Wl,--as-needed"
[ "${AGGR_FUSE_LLD}" = "1" ] && _ldf="${_ldf} -fuse-ld=lld"

# Exporta flags (musl-friendly; evite gambiarras específicas de glibc)
export CFLAGS="${CFLAGS:-${_base_opt} ${_marchmtune} ${_lto} ${_pie_cc}}"
export CXXFLAGS="${CXXFLAGS:-${_base_opt} ${_marchmtune} ${_lto} ${_pie_cc}}"
export LDFLAGS="${LDFLAGS:-${_ldf} ${_lto} ${_pie_ld}}"

# pkg-config orientado ao sysroot
export PKG_CONFIG_SYSROOT_DIR="${PKG_CONFIG_SYSROOT_DIR:-${SYSROOT}}"
export PKG_CONFIG_DIR=
export PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR:-${SYSROOT}/usr/lib/pkgconfig:${SYSROOT}/usr/share/pkgconfig}"

# Dicas aos helpers
export ADM_PREFER_MUSL="1"
export ADM_PREFER_CLANG="1"          # preferir clang quando presente
export ADM_PREFER_LLD="1"
export ADM_TARGET_TRIPLET="${TARGET}"
export ADM_ENABLE_LTO="${AGGR_LTO}"
export ADM_CMAKE_GENERATOR="${ADM_CMAKE_GENERATOR:-Ninja}"

# Nota:
# - Se necessário forçar o dynamic loader da musl:
#   export LDFLAGS="${LDFLAGS} -Wl,--dynamic-linker=/lib/ld-musl-<arch>.so.1"
#   (helpers podem decidir isso por build_type/alvo)
