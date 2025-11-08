# ADM Profile: musl-default
# Compila visando musl por padrão (triplet *-musl), propagando --target e --sysroot.
# Use com GCC ou Clang. Se Clang existir, ele será preferido (combina bem com clang-default).
# Ativação: adm --profile musl-default

if [ -n "${_ADM_PROFILE_MUSL_DEFAULT:-}" ]; then return 0 2>/dev/null || exit 0; fi
_ADM_PROFILE_MUSL_DEFAULT=1

export PROFILE_NAME="musl-default"
export PROFILE_VERSION="1.0"

# Ajuste o triplet alvo aqui (x86_64-linux-musl por padrão):
: "${MUSL_TARGET:=x86_64-linux-musl}"
export TARGET="${TARGET:-${MUSL_TARGET}}"

# O sysroot deve apontar para o rootfs onde a musl foi instalada (normalmente / do stage/sistema)
# Quando o ADM é invocado com --root, 14-adm-profile.sh deve preencher ADM_EFFECTIVE_ROOT.
if [ -n "${ADM_EFFECTIVE_ROOT:-}" ]; then
  : "${MUSL_SYSROOT:=/}"
  export SYSROOT="${SYSROOT:-${MUSL_SYSROOT}}"
  # PATH para os binários do sysroot (caso tenha wrappers/toolchains dentro do root)
  if [ -d "${ADM_EFFECTIVE_ROOT}/usr/bin" ]; then
    export PATH="${ADM_EFFECTIVE_ROOT}/usr/bin:${PATH}"
  fi
else
  # Fallback sem --root: sysroot vazio implica ambiente do host.
  : "${MUSL_SYSROOT:=/}"
  export SYSROOT="${SYSROOT:-${MUSL_SYSROOT}}"
fi

# Preferências de compilador: Clang (se presente) com --target e --sysroot;
# caso contrário GCC com --target/--sysroot se suportado na sua toolchain.
if command -v clang >/dev/null 2>&1; then
  export CC="clang --target=${TARGET} --sysroot=${SYSROOT}"
  export CXX="clang++ --target=${TARGET} --sysroot=${SYSROOT}"
  export CPP="clang-cpp --target=${TARGET} --sysroot=${SYSROOT}"
else
  # GCC cross para musl: espera-se que exista ${TARGET}-gcc; se não houver, caímos em gcc + specs locais.
  if command -v "${TARGET}-gcc" >/dev/null 2>&1; then
    export CC="${TARGET}-gcc --sysroot=${SYSROOT}"
    export CXX="${TARGET}-g++ --sysroot=${SYSROOT}"
  else
    # Fallback “melhor esforço” — pode exigir specs personalizados no GCC do host.
    command -v gcc >/dev/null 2>&1 && export CC="gcc --sysroot=${SYSROOT}"
    command -v g++ >/dev/null 2>&1 && export CXX="g++ --sysroot=${SYSROOT}"
  fi
fi

# Linker: preferir LLD se disponível (bom com musl)
if command -v ld.lld >/dev/null 2>&1; then
  export LD="ld.lld"
  export LDFLAGS="${LDFLAGS:--Wl,--as-needed} -fuse-ld=lld"
fi

# Ferramentas auxiliares — preferir LLVM se disponíveis (compatíveis com musl)
command -v llvm-ar >/dev/null 2>&1     && export AR="llvm-ar"
command -v llvm-ranlib >/dev/null 2>&1 && export RANLIB="llvm-ranlib"
command -v llvm-nm >/dev/null 2>&1     && export NM="llvm-nm"
command -v llvm-strip >/dev/null 2>&1  && export STRIP="llvm-strip"

# Flags comuns (seguras para musl; evite extensões glibc por padrão)
: "${ADM_OPT_LEVEL:=O2}"
: "${ADM_COMMON_FLAGS:=-${ADM_OPT_LEVEL} -pipe}"
export CFLAGS="${CFLAGS:-${ADM_COMMON_FLAGS}}"
export CXXFLAGS="${CXXFLAGS:-${ADM_COMMON_FLAGS}}"

# Algumas builds precisam do caminho do dynamic loader de musl; não forçamos aqui para não quebrar.
# Se necessário, passe via LDFLAGS extra ao pacote específico:
#   export LDFLAGS="${LDFLAGS} -Wl,--dynamic-linker=/lib/ld-musl-<arch>.so.1"
# Helpers podem injetar isso quando detectarem necessidade (08-adm-build-system-helpers.sh).

# pkg-config deve apontar para o sysroot quando presente; muitos setups já honram PKG_CONFIG_SYSROOT_DIR
if [ -n "${ADM_EFFECTIVE_ROOT:-}" ]; then
  export PKG_CONFIG_SYSROOT_DIR="${PKG_CONFIG_SYSROOT_DIR:-${SYSROOT}}"
  export PKG_CONFIG_DIR=
  export PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR:-${SYSROOT}/usr/lib/pkgconfig:${SYSROOT}/usr/share/pkgconfig}"
fi

# Buildsystems: preferências para helpers
export ADM_PREFER_MUSL="1"
export ADM_TARGET_TRIPLET="${TARGET}"
