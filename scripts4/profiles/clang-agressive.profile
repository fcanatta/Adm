# ADM Profile: clang-aggressive
# Objetivo: Clang/LLD como toolchain padrão com flags agressivas (O3, march=native, ThinLTO).
# AVISO: pode quebrar builds sensíveis a agressividade de otimização.
# Ativação: adm --profile clang-aggressive

if [ -n "${_ADM_PROFILE_CLANG_AGGR:-}" ]; then return 0 2>/dev/null || exit 0; fi
_ADM_PROFILE_CLANG_AGGR=1

export PROFILE_NAME="clang-aggressive"
export PROFILE_VERSION="1.0"

# Preferir binários do ROOT quando usado com --root
if [ -n "${ADM_EFFECTIVE_ROOT:-}" ] && [ -d "${ADM_EFFECTIVE_ROOT}/usr/bin" ]; then
  export PATH="${ADM_EFFECTIVE_ROOT}/usr/bin:${PATH}"
fi

# Preferências de ferramentas LLVM
command -v clang >/dev/null 2>&1  && export CC="clang"
command -v clang++ >/dev/null 2>&1 && export CXX="clang++"
command -v clang-cpp >/dev/null 2>&1 && export CPP="clang-cpp"

command -v ld.lld >/dev/null 2>&1   && export LD="ld.lld"
command -v llvm-ar >/dev/null 2>&1  && export AR="llvm-ar"
command -v llvm-ranlib >/dev/null 2>&1 && export RANLIB="llvm-ranlib"
command -v llvm-nm >/dev/null 2>&1  && export NM="llvm-nm"
command -v llvm-objcopy >/dev/null 2>&1 && export OBJCOPY="llvm-objcopy"
command -v llvm-objdump >/dev/null 2>&1 && export OBJDUMP="llvm-objdump"
command -v llvm-strip >/dev/null 2>&1 && export STRIP="llvm-strip"
command -v llvm-size >/dev/null 2>&1 && export SIZE="llvm-size"

# Parâmetros de agressividade (pode customizar via env antes do apply)
: "${AGGR_OPT_LEVEL:=O3}"              # O3 por padrão; considere 'Ofast' (ver abaixo)
: "${AGGR_USE_OFAST:=0}"               # 1 para Ofast (não-estrito), 0 para O3
: "${AGGR_MARCH:=native}"              # 'native' usa a CPU do build (não reproduzível)
: "${AGGR_MTUNE:=native}"
: "${AGGR_LTO:=thin}"                  # thin|full|off
: "${AGGR_USE_PIE:=1}"                 # 1: adiciona -fPIE/-pie para executáveis (melhora ASLR)
: "${AGGR_FUSE_LLD:=1}"                # 1: usa LLD
: "${AGGR_STRIP_BIN:=0}"               # 1: strip pós-build (pode complicar debug)
: "${AGGR_NDEBUG:=1}"                  # 1: define NDEBUG (remove asserts em muitos projetos)

# Flags base
_base_opt="-O3 -pipe"
[ "${AGGR_USE_OFAST}" = "1" ] && _base_opt="-Ofast -fno-math-errno -ffp-contract=fast -funsafe-math-optimizations -pipe"
_marchmtune=""
[ -n "${AGGR_MARCH}" ] && _marchmtune="${_marchmtune} -march=${AGGR_MARCH}"
[ -n "${AGGR_MTUNE}" ] && _marchmtune="${_marchmtune} -mtune=${AGGR_MTUNE}"

# LTO
_lto=""
case "${AGGR_LTO}" in
  thin|Thin|THIN) _lto="-flto=thin";;
  full|FULL)      _lto="-flto";;
  off|OFF|0|"")   _lto="";;
esac

# PIE
_pie_cc=""; _pie_ld=""
[ "${AGGR_USE_PIE}" = "1" ] && { _pie_cc="-fPIE"; _pie_ld="-pie"; }

# Linker
_ldf="-Wl,--as-needed"
[ "${AGGR_FUSE_LLD}" = "1" ] && _ldf="${_ldf} -fuse-ld=lld"

# Exporte flags finais (não sobrescreve se já setadas externamente)
export CFLAGS="${CFLAGS:-${_base_opt} ${_marchmtune} ${_lto} ${_pie_cc}}"
export CXXFLAGS="${CXXFLAGS:-${_base_opt} ${_marchmtune} ${_lto} ${_pie_cc}}"
export LDFLAGS="${LDFLAGS:-${_ldf} ${_lto} ${_pie_ld}}"

# NDEBUG (remove asserts) — opcionalmente agressivo
[ "${AGGR_NDEBUG}" = "1" ] && export CPPFLAGS="${CPPFLAGS:-} -DNDEBUG"

# Preferências para helpers (08-adm-build-system-helpers.sh)
export ADM_PREFER_CLANG="1"
export ADM_PREFER_LLD="1"
export ADM_ENABLE_LTO="${AGGR_LTO}"
export ADM_CMAKE_GENERATOR="${ADM_CMAKE_GENERATOR:-Ninja}"

# Observações:
# - 'Ofast' pode quebrar conformidade (IEEE/strict aliasing/UB). Use somente se aceitar riscos.
# - 'march=native' gera binários não portáveis para outras CPUs.
# - Alguns projetos ignoram LDFLAGS; helpers devem injetar CMake/Meson equivalentes.
