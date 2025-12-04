# /etc/adm/profiles/musl.profile
# Profile de build otimizado para desktop (musl)

# Número de jobs em paralelo
if command -v getconf >/dev/null 2>&1; then
    ADM_NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
elif command -v nproc >/dev/null 2>&1; then
    ADM_NPROC="$(nproc 2>/dev/null || echo 1)"
else
    ADM_NPROC=1
fi
export MAKEFLAGS="-j${ADM_NPROC}"

# Rootfs padrão para musl
export ROOTFS_MUSL="/opt/systems/musl-rootfs"
export ADM_DEFAULT_ROOTFS="$ROOTFS_MUSL"

# Toolchain padrão para musl
# Se você tiver um triplet específico (ex: x86_64-linux-musl-gcc),
# pode exportar CC antes de chamar o adm para sobrescrever.
if command -v musl-gcc >/dev/null 2>&1; then
    export CC="${CC:-musl-gcc}"
else
    # fallback para gcc normal, caso não exista musl-gcc
    export CC="${CC:-gcc}"
fi
export CXX="${CXX:-g++}"
export AR="${AR:-ar}"
export NM="${NM:-nm}"
export RANLIB="${RANLIB:-ranlib}"
export STRIP="${STRIP:-strip}"
export OBJDUMP="${OBJDUMP:-objdump}"
export READELF="${READELF:-readelf}"

# CFLAGS/CXXFLAGS – mesmas ideias do glibc, ajustadas para musl
CFLAGS_OPT="-O2 -pipe -march=native -mtune=native -fno-plt -fstack-protector-strong"
export CFLAGS="${CFLAGS:-$CFLAGS_OPT}"
export CXXFLAGS="${CXXFLAGS:-$CFLAGS}"

# Hardening via CPPFLAGS
CPPFLAGS_OPT="-D_FORTIFY_SOURCE=2"
export CPPFLAGS="${CPPFLAGS:-$CPPFLAGS_OPT}"

# LDFLAGS – idem glibc (funciona bem com musl também)
LDFLAGS_OPT="-Wl,-O1,--as-needed,-z,relro,-z,now"
export LDFLAGS="${LDFLAGS:-$LDFLAGS_OPT}"

# PKG_CONFIG_PATH – considerando musl em /usr/musl e rootfs musl
ADM_PKGCFG_BASE="/usr/musl/lib/pkgconfig:/usr/musl/share/pkgconfig"
ADM_PKGCFG_BASE="${ADM_PKGCFG_BASE}:/usr/lib/pkgconfig:/usr/share/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig"

if [ -d "${ROOTFS_MUSL}/usr/lib/pkgconfig" ]; then
    ADM_PKGCFG_BASE="${ROOTFS_MUSL}/usr/lib/pkgconfig:${ADM_PKGCFG_BASE}"
fi
if [ -d "${ROOTFS_MUSL}/usr/share/pkgconfig" ]; then
    ADM_PKGCFG_BASE="${ROOTFS_MUSL}/usr/share/pkgconfig:${ADM_PKGCFG_BASE}"
fi
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-$ADM_PKGCFG_BASE}"

# PATH – se quiser priorizar ferramentas dentro do rootfs musl
if [ -d "${ROOTFS_MUSL}/usr/bin" ]; then
    case ":$PATH:" in
        *":${ROOTFS_MUSL}/usr/bin:"*) ;;
        *) export PATH="${ROOTFS_MUSL}/usr/bin:${PATH}" ;;
    esac
fi

export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
