# /usr/src/adm/profiles/glibc.profile
# Profile: glibc
export ADM_PROFILE_NAME="glibc"

# Arquitetura / triplet
export ADM_ARCH="x86_64"
export ADM_TRIPLET="x86_64-pc-linux-gnu"

# Libc alvo
export ADM_LIBC="glibc"

# Rootfs e sysroot
export ADM_ROOTFS="/opt/systems/glibc-rootfs"
export ADM_SYSROOT="${ADM_ROOTFS}"

# Layout de instalação dentro do rootfs
export ADM_PREFIX="/usr"
export ADM_SYSLIBDIR="/lib"      # troque pra /lib64 se for seu padrão

# Toolchain principal deste profile
export ADM_TOOLCHAIN_PREFIX="/opt/toolchains/glibc-toolchain"
export ADM_TOOLCHAIN_TRIPLET="${ADM_TRIPLET}"

# Compiladores padrão (GCC)
export CC="${ADM_TOOLCHAIN_PREFIX}/bin/${ADM_TRIPLET}-gcc"
export CXX="${ADM_TOOLCHAIN_PREFIX}/bin/${ADM_TRIPLET}-g++"
export AR="${ADM_TOOLCHAIN_PREFIX}/bin/${ADM_TRIPLET}-ar"
export RANLIB="${ADM_TOOLCHAIN_PREFIX}/bin/${ADM_TRIPLET}-ranlib"
export LD="${ADM_TOOLCHAIN_PREFIX}/bin/${ADM_TRIPLET}-ld"

# Flags mínimas
export CFLAGS="--sysroot=${ADM_SYSROOT}"
export CXXFLAGS="--sysroot=${ADM_SYSROOT}"
export LDFLAGS="--sysroot=${ADM_SYSROOT}"

# Jobs padrão
if command -v nproc >/dev/null 2>&1; then
  export ADM_MAKE_JOBS="$(nproc)"
else
  export ADM_MAKE_JOBS="4"
fi

# PATH – toolchain primeiro, depois sistema
export PATH="${ADM_TOOLCHAIN_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin"
