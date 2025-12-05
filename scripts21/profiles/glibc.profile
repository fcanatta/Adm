# /opt/adm/profiles/glibc.profile
# Profile para sistema baseado em glibc
# Otimização moderada e segura para uso diário.

# Detecta arquitetura
ARCH="$(uname -m)"

# CHOST padrão (ajuste se estiver fazendo cross-compile)
case "$ARCH" in
    x86_64)
        export CHOST="x86_64-pc-linux-gnu"
        CPU_FLAGS="-march=x86-64 -mtune=generic"
        ;;
    aarch64)
        export CHOST="aarch64-unknown-linux-gnu"
        CPU_FLAGS="-march=armv8-a"
        ;;
    *)
        export CHOST="${ARCH}-pc-linux-gnu"
        CPU_FLAGS=""
        ;;
esac

# Toolchain
export CC="${CC:-gcc}"
export CXX="${CXX:-g++}"
export AR="${AR:-gcc-ar}"
export RANLIB="${RANLIB:-gcc-ranlib}"
export NM="${NM:-gcc-nm}"
export STRIP="${STRIP:-strip}"
export LD="${LD:-ld}"

# Otimização padrão (segura)
BASE_CFLAGS="-O2 -pipe -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
-fstack-clash-protection -fno-plt"
BASE_CXXFLAGS="$BASE_CFLAGS"

# Descomente se quiser otimizar especificamente para a máquina local
# (pode quebrar binários se você reutilizar em outra máquina mais antiga)
# CPU_FLAGS="-march=native"

export CFLAGS="${CFLAGS:-$CPU_FLAGS $BASE_CFLAGS}"
export CXXFLAGS="${CXXFLAGS:-$CPU_FLAGS $BASE_CXXFLAGS}"

# Flags de linkagem (hardening + limpeza de dependências)
export LDFLAGS="${LDFLAGS:--Wl,-O1,-z,relro,-z,now -Wl,--as-needed}"

# Onde ficarão o sistema alvo e libs:
# O script principal já exporta ROOTFS=/opt/systems/glibc-rootfs
export ROOTFS="${ROOTFS:-/opt/systems/glibc-rootfs}"

# PKG-CONFIG apontando para o ROOTFS (para resolver deps no rootfs)
export PKG_CONFIG_PATH="$ROOTFS/usr/lib/pkgconfig:$ROOTFS/usr/share/pkgconfig:$ROOTFS/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PKG_CONFIG_LIBDIR="$ROOTFS/usr/lib/pkgconfig:$ROOTFS/usr/share/pkgconfig:${PKG_CONFIG_LIBDIR:-}"

# Prefix padrão dos pacotes
export PREFIX="${PREFIX:-/usr}"

# PATH: prioriza binários do ROOTFS, mas mantém os do host
export PATH="$ROOTFS/usr/bin:$ROOTFS/bin:$PATH"

# Locale padrão (ajuste conforme desejar)
export LANG="${LANG:-pt_BR.UTF-8}"
export LC_ALL="$LANG"

# Configuração automática para scripts autoconf ( ./configure )
# Evita algumas perguntas e sugere destino em /usr
export CONFIG_SITE="${CONFIG_SITE:-$ROOTFS/usr/share/config.site}"

# Make padrão
export MAKEFLAGS="${MAKEFLAGS:--j$(nproc)}"

# No fim do glibc.profile ou musl.profile:
if [[ "${ADM_PERF_LEVEL:-}" == "high" ]]; then
    # sobrescreve flags com perfil agressivo
    . /opt/adm/profiles/highperf.profile
fi
