# /opt/adm/profiles/musl.profile
# Profile para sistema baseado em musl
# Focado em simplicidade e compatibilidade, com boa otimização.

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64)
        export CHOST="x86_64-linux-musl"
        CPU_FLAGS="-march=x86-64 -mtune=generic"
        ;;
    aarch64)
        export CHOST="aarch64-linux-musl"
        CPU_FLAGS="-march=armv8-a"
        ;;
    *)
        export CHOST="${ARCH}-linux-musl"
        CPU_FLAGS=""
        ;;
esac

# Toolchain: prioriza musl-gcc, depois <arch>-linux-musl-gcc, por fim gcc
if command -v musl-gcc >/dev/null 2>&1; then
    export CC="${CC:-musl-gcc}"
elif command -v "${CHOST}-gcc" >/dev/null 2>&1; then
    export CC="${CC:-${CHOST}-gcc}"
else
    # fallback: não é o ideal, mas permite compilar algo até o toolchain musl ficar pronto
    export CC="${CC:-gcc}"
    echo "[musl.profile] AVISO: musl-gcc não encontrado, usando gcc do host." >&2
fi

if command -v "${CHOST}-g++" >/dev/null 2>&1; then
    export CXX="${CXX:-${CHOST}-g++}"
else
    export CXX="${CXX:-g++}"
fi

export AR="${AR:-${CHOST}-ar}"
export RANLIB="${RANLIB:-${CHOST}-ranlib}"
export NM="${NM:-${CHOST}-nm}"
export STRIP="${STRIP:-${CHOST}-strip}"
export LD="${LD:-${CHOST}-ld}"

# Caso o binário <CHOST>-ar/etc não exista, caímos para os genéricos
command -v "$AR" >/dev/null 2>&1 || AR="ar"
command -v "$RANLIB" >/dev/null 2>&1 || RANLIB="ranlib"
command -v "$NM" >/dev/null 2>&1 || NM="nm"
command -v "$STRIP" >/dev/null 2>&1 || STRIP="strip"
command -v "$LD" >/dev/null 2>&1 || LD="ld"

# Otimização pensada para musl (um pouco mais enxuta)
BASE_CFLAGS="-O2 -pipe -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-plt"
BASE_CXXFLAGS="$BASE_CFLAGS"

# Para sistemas musl frequentemente se busca algo mais leve;
# se quiser focar em tamanho, descomente:
# BASE_CFLAGS="-Os -pipe -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-plt"
# BASE_CXXFLAGS="$BASE_CFLAGS"

# Descomente para otimizar só para esta máquina:
# CPU_FLAGS="-march=native"

export CFLAGS="${CFLAGS:-$CPU_FLAGS $BASE_CFLAGS}"
export CXXFLAGS="${CXXFLAGS:-$CPU_FLAGS $BASE_CXXFLAGS}"

# Linkagem: para musl você pode escolher estático ou dinâmico.
# Dinâmico padrão (recomendado para desktop):
export LDFLAGS="${LDFLAGS:--Wl,-O1,-z,relro,-z,now -Wl,--as-needed}"

# Se quiser tudo estático, descomente (e comente a linha acima):
# export LDFLAGS="${LDFLAGS:--static -Wl,-O1,--as-needed}"

# RootFS musl
export ROOTFS="${ROOTFS:-/opt/systems/musl-rootfs}"

# PKG-CONFIG apontando para o rootfs musl
export PKG_CONFIG_PATH="$ROOTFS/usr/lib/pkgconfig:$ROOTFS/usr/share/pkgconfig:$ROOTFS/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PKG_CONFIG_LIBDIR="$ROOTFS/usr/lib/pkgconfig:$ROOTFS/usr/share/pkgconfig:${PKG_CONFIG_LIBDIR:-}"

# Prefixo padrão
export PREFIX="${PREFIX:-/usr}"

# PATH: prioriza binários do ROOTFS musl
export PATH="$ROOTFS/usr/bin:$ROOTFS/bin:$PATH"

# Locale (musl também suporta UTF-8 normal se tiver as locales instaladas)
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="$LANG"

# CONFIG_SITE para autoconf, se você quiser algo específico para musl
# Você pode criar um config.site com ajustes de compatibilidade se precisar
export CONFIG_SITE="${CONFIG_SITE:-$ROOTFS/usr/share/config.musl.site}"

# Make paralelo
export MAKEFLAGS="${MAKEFLAGS:--j$(nproc)}"
