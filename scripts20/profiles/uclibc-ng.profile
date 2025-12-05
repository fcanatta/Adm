# Profile: uclibc-ng
export ADM_PROFILE_NAME="uclibc-ng"

export ADM_ARCH="x86_64"
export ADM_TRIPLET="x86_64-uclibc-linux"

export ADM_LIBC="uclibc-ng"

export ADM_ROOTFS="/opt/systems/uclibc-ng-rootfs"
export ADM_SYSROOT="${ADM_ROOTFS}"

export ADM_PREFIX="/usr"
export ADM_SYSLIBDIR="/lib"

export ADM_TOOLCHAIN_PREFIX="/opt/toolchains/uclibc-ng-toolchain"
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
