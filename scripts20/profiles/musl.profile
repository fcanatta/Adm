# Profile: musl
export ADM_PROFILE_NAME="musl"

export ADM_ARCH="x86_64"
export ADM_TRIPLET="x86_64-linux-musl"

export ADM_LIBC="musl"

export ADM_ROOTFS="/opt/systems/musl-rootfs"
export ADM_SYSROOT="${ADM_ROOTFS}"

export ADM_PREFIX="/usr"
export ADM_SYSLIBDIR="/lib"      # musl normalmente usa /lib

export ADM_TOOLCHAIN_PREFIX="/opt/toolchains/musl-toolchain"
export ADM_TOOLCHAIN_TRIPLET="${ADM_TRIPLET}"

export CC="${ADM_TOOLCHAIN_PREFIX}/bin/${ADM_TRIPLET}-gcc"
export CXX="${ADM_TOOLCHAIN_PREFIX}/bin/${ADM_TRIPLET}-g++"
export AR="${ADM_TOOLCHAIN_PREFIX}/bin/${ADM_TRIPLET}-ar"
export RANLIB="${ADM_TOOLCHAIN_PREFIX}/bin/${ADM_TRIPLET}-ranlib"
export LD="${ADM_TOOLCHAIN_PREFIX}/bin/${ADM_TRIPLET}-ld"

export CFLAGS="--sysroot=${ADM_SYSROOT}"
export CXXFLAGS="--sysroot=${ADM_SYSROOT}"
export LDFLAGS="--sysroot=${ADM_SYSROOT}"

if command -v nproc >/dev/null 2>&1; then
  export ADM_MAKE_JOBS="$(nproc)"
else
  export ADM_MAKE_JOBS="4"
fi

export PATH="${ADM_TOOLCHAIN_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin"
