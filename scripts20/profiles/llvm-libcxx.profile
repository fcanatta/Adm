# Profile: llvm-libc++
export ADM_PROFILE_NAME="llvm-libcxx"

export ADM_ARCH="x86_64"
export ADM_TRIPLET="x86_64-pc-linux-gnu"

# Continua usando glibc como libc base
export ADM_LIBC="glibc"
export ADM_CXX_RUNTIME="libc++"

export ADM_ROOTFS="/opt/systems/llvm-libcxx-rootfs"
export ADM_SYSROOT="${ADM_ROOTFS}"

export ADM_PREFIX="/usr"
export ADM_SYSLIBDIR="/lib"

# Toolchain LLVM deste profile
export ADM_TOOLCHAIN_PREFIX="/opt/toolchains/llvm-libcxx-toolchain"
export ADM_TOOLCHAIN_TRIPLET="${ADM_TRIPLET}"

# Compiladores LLVM
export CC="${ADM_TOOLCHAIN_PREFIX}/bin/clang"
export CXX="${ADM_TOOLCHAIN_PREFIX}/bin/clang++"
export AR="${ADM_TOOLCHAIN_PREFIX}/bin/llvm-ar"
export RANLIB="${ADM_TOOLCHAIN_PREFIX}/bin/llvm-ranlib"
export LD="${ADM_TOOLCHAIN_PREFIX}/bin/ld.lld"

# Flags para usar libc++
export CFLAGS="--sysroot=${ADM_SYSROOT}"
export CXXFLAGS="--sysroot=${ADM_SYSROOT} -stdlib=libc++"
export LDFLAGS="--sysroot=${ADM_SYSROOT} -stdlib=libc++"

if command -v nproc >/dev/null 2>&1; then
  export ADM_MAKE_JOBS="$(nproc)"
else
  export ADM_MAKE_JOBS="4"
fi

export PATH="${ADM_TOOLCHAIN_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin"
