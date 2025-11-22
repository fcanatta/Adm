# /root/usr/src/adm/profiles/toolchain/safe-glibc.profile (exemplo)
export ADM_CROSS_TARGET="x86_64-lfs-linux-gnu"
export ADM_CROSS_PREFIX="/usr/cross"
export ADM_SYSROOT="/"

export CFLAGS="-O2 -pipe"
export CXXFLAGS="$CFLAGS"
export MAKEFLAGS="-j$(nproc)"
