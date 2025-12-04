# /etc/adm/profiles/glibc.profile
# Profile de build otimizado para desktop (glibc)

# Número de jobs em paralelo
if command -v getconf >/dev/null 2>&1; then
    ADM_NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
elif command -v nproc >/dev/null 2>&1; then
    ADM_NPROC="$(nproc 2>/dev/null || echo 1)"
else
    ADM_NPROC=1
fi
export MAKEFLAGS="-j${ADM_NPROC}"

# Rootfs padrão para glibc
export ROOTFS_GLIBC="/opt/systems/glibc-rootfs"
export ADM_DEFAULT_ROOTFS="$ROOTFS_GLIBC"

# Toolchain padrão (override se já tiver setado fora)
export CC="${CC:-gcc}"
export CXX="${CXX:-g++}"
export AR="${AR:-ar}"
export NM="${NM:-nm}"
export RANLIB="${RANLIB:-ranlib}"
export STRIP="${STRIP:-strip}"
export OBJDUMP="${OBJDUMP:-objdump}"
export READELF="${READELF:-readelf}"

# CFLAGS/CXXFLAGS – foco em desktop (ótimo equilíbrio perf/compat)
# -O2           => boa otimização
# -pipe        => compilações mais rápidas em desktop
# -march=native/-mtune=native => otimiza para a CPU local
# -fno-plt     => menor overhead de chamadas dinâmicas
# -fstack-protector-strong => proteção de stack razoável
CFLAGS_OPT="-O2 -pipe -march=native -mtune=native -fno-plt -fstack-protector-strong"
export CFLAGS="${CFLAGS:-$CFLAGS_OPT}"
export CXXFLAGS="${CXXFLAGS:-$CFLAGS}"

# Hardening leve via CPPFLAGS
# _FORTIFY_SOURCE=2 exige -O2 ou maior (já garantido)
CPPFLAGS_OPT="-D_FORTIFY_SOURCE=2"
export CPPFLAGS="${CPPFLAGS:-$CPPFLAGS_OPT}"

# LDFLAGS – otimização + hardening moderado
# -Wl,-O1      => otimiza o linker
# --as-needed  => evita link desnecessário
# -z,relro/now => proteção extra da tabela de relocação
LDFLAGS_OPT="-Wl,-O1,--as-needed,-z,relro,-z,now"
export LDFLAGS="${LDFLAGS:-$LDFLAGS_OPT}"

# PKG_CONFIG_PATH – host + opcionalmente rootfs
# Você pode ajustar se quiser linkar contra libs no rootfs.
ADM_PKGCFG_BASE="/usr/lib/pkgconfig:/usr/share/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig"
if [ -d "${ROOTFS_GLIBC}/usr/lib/pkgconfig" ]; then
    ADM_PKGCFG_BASE="${ROOTFS_GLIBC}/usr/lib/pkgconfig:${ADM_PKGCFG_BASE}"
fi
if [ -d "${ROOTFS_GLIBC}/usr/share/pkgconfig" ]; then
    ADM_PKGCFG_BASE="${ROOTFS_GLIBC}/usr/share/pkgconfig:${ADM_PKGCFG_BASE}"
fi
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-$ADM_PKGCFG_BASE}"

# PATH – caso queira adicionar ferramentas específicas do rootfs (opc.)
if [ -d "${ROOTFS_GLIBC}/usr/bin" ]; then
    case ":$PATH:" in
        *":${ROOTFS_GLIBC}/usr/bin:"*) ;;
        *) export PATH="${ROOTFS_GLIBC}/usr/bin:${PATH}" ;;
    esac
fi

# Locale básico (opcional, mas ajuda em build/log)
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
