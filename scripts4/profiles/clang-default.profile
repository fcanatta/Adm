# ADM Profile: clang-default
# Torna Clang o compilador padrão e LLD o linker padrão.
# Requisitos: llvm, clang, lld instalados em ${ROOT}/usr.
# Ativação: adm --profile clang-default  (ou 14-adm-profile.sh apply --name clang-default)

if [ -n "${_ADM_PROFILE_CLANG_DEFAULT:-}" ]; then return 0 2>/dev/null || exit 0; fi
_ADM_PROFILE_CLANG_DEFAULT=1

export PROFILE_NAME="clang-default"
export PROFILE_VERSION="1.0"

# Preferir /usr/bin do ROOT (quando executando com --root)
if [ -n "${ADM_EFFECTIVE_ROOT:-}" ] && [ -d "${ADM_EFFECTIVE_ROOT}/usr/bin" ]; then
  export PATH="${ADM_EFFECTIVE_ROOT}/usr/bin:${PATH}"
fi

# Ferramentas LLVM/Clang (com fallback silencioso para ferramentas GNU se ausentes)
command -v clang >/dev/null 2>&1  && export CC="clang"
command -v clang++ >/dev/null 2>&1 && export CXX="clang++"
command -v clang-cpp >/dev/null 2>&1 && export CPP="clang-cpp"

command -v ld.lld >/dev/null 2>&1   && export LD="ld.lld"
command -v llvm-ar >/dev/null 2>&1  && export AR="llvm-ar"
command -v llvm-ranlib >/dev/null 2>&1 && export RANLIB="llvm-ranlib"
command -v llvm-nm >/dev/null 2>&1  && export NM="llvm-nm"
command -v llvm-objcopy >/dev/null 2>&1 && export OBJCOPY="llvm-objcopy"
command -v llvm-objdump >/dev/null 2>&1 && export OBJDUMP="llvm-objdump"
command -v llvm-readelf >/dev/null 2>&1 && export READELF="llvm-readelf"
command -v llvm-strip >/dev/null 2>&1 && export STRIP="llvm-strip"
command -v llvm-size >/dev/null 2>&1 && export SIZE="llvm-size"

# Flags sensatas para Clang como padrão (sem LTO por default; ajuste conforme seu profile aggressive)
: "${ADM_OPT_LEVEL:=O2}"
: "${ADM_COMMON_FLAGS:=-${ADM_OPT_LEVEL} -pipe}"
export CFLAGS="${CFLAGS:-${ADM_COMMON_FLAGS}}"
export CXXFLAGS="${CXXFLAGS:-${ADM_COMMON_FLAGS}}"

# Forçar LLD quando Clang estiver linkando (muitos projetos respeitam -fuse-ld=lld)
# OBS: alguns buildsystems ignoram LDFLAGS; manter também via vars específicas quando cabível.
if command -v ld.lld >/dev/null 2>&1; then
  export LDFLAGS="${LDFLAGS:--Wl,--as-needed} -fuse-ld=lld"
fi

# PKG-CONFIG padrão
command -v pkg-config >/dev/null 2>&1 && export PKG_CONFIG="${PKG_CONFIG:-pkg-config}"

# CMake/Ninja preferidos (não obrigatório, mas acelera e padroniza)
command -v ninja >/dev/null 2>&1 && export ADM_CMAKE_GENERATOR="${ADM_CMAKE_GENERATOR:-Ninja}"

# Buildsystems: dicas comuns (consumidas por 08-adm-build-system-helpers.sh)
export ADM_PREFER_LLD="1"             # helpers podem honrar isso com flags específicas
export ADM_PREFER_CLANG="1"           # helpers podem preferir clang/clang++

# Segurança: não deixar o perfil quebrar builds que forçam GCC/LD-BFD nos próprios scripts.
# Apenas damos preferência; se o projeto sobrescreve, deixamos seguir.
