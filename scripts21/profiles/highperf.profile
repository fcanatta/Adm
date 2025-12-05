# /opt/adm/profiles/highperf.profile
# Profile de otimizações AGRESSIVAS (alto desempenho).
#
# Use com cuidado: pode quebrar alguns pacotes, aumentar tempo de build
# e gerar binários menos portáveis (dependentes da CPU atual).

ARCH="$(uname -m)"

# CHOST "genérico". Se você já tem CHOST nos outros profiles (glibc/musl),
# este profile não mexe nele por padrão.
: "${CHOST:=$ARCH-pc-linux-gnu}"

############################################
# Detecta GCC x Clang (apenas para ajustes) #
############################################

if command -v clang >/dev/null 2>&1 && [[ "${CC:-}" == clang* ]]; then
    COMPILER=clang
else
    COMPILER=gcc
fi

############################################
# Flags base agressivas                    #
############################################

# Otimizações bem fortes, focadas na CPU local
CPU_FLAGS="-march=native -mtune=native"

# Comuns para C/C++
COMMON_OPT="-O3 -pipe -fomit-frame-pointer -fstrict-aliasing -ftree-vectorize"

# Proteções básicas ainda mantidas (segurança razoável)
HARDENING="-fstack-protector-strong -D_FORTIFY_SOURCE=2"

# Algumas coisas mudam dependendo do compilador
if [[ "$COMPILER" == "gcc" ]]; then
    # LTO clássico do GCC
    LTO_FLAGS="-flto"

    # Comentados: GRAPHITE costuma depender de build do gcc com suporte
    # e pode falhar se não estiver disponível.
    # EXTRA="-fgraphite-identity -floop-nest-optimize"
    EXTRA=""
else
    # clang: LTO integrado; -flto também funciona, mas depende do toolchain
    LTO_FLAGS="-flto"
    EXTRA=""
fi

BASE_CFLAGS="$CPU_FLAGS $COMMON_OPT $HARDENING $EXTRA"
BASE_CXXFLAGS="$BASE_CFLAGS"

############################################
# Exporta CFLAGS/CXXFLAGS/LDFLAGS          #
############################################

# Se já tiver CFLAGS anteriores, este profile SOBRESCREVE (intencionalmente).
export CFLAGS="$BASE_CFLAGS"
export CXXFLAGS="$BASE_CXXFLAGS"

# LTO também no link
export LDFLAGS="${LDFLAGS:-} $LTO_FLAGS -Wl,-O2,-z,relro,-z,now -Wl,--as-needed"

############################################
# Toolchain preparado pra LTO              #
############################################

# Para que LTO funcione bem com GCC, usar wrappers gcc-ar/gcc-ranlib/gcc-nm.
# Se não existirem, cai pros genéricos.
if [[ "$COMPILER" == "gcc" ]]; then
    command -v gcc-ar     >/dev/null 2>&1 && export AR="${AR:-gcc-ar}"
    command -v gcc-ranlib >/dev/null 2>&1 && export RANLIB="${RANLIB:-gcc-ranlib}"
    command -v gcc-nm     >/dev/null 2>&1 && export NM="${NM:-gcc-nm}"
fi

: "${AR:=ar}"
: "${RANLIB:=ranlib}"
: "${NM:=nm}"
: "${STRIP:=strip}"
: "${LD:=ld}"

############################################
# Make paralelo mais agressivo             #
############################################

# Se já tiver MAKEFLAGS, não mexo; caso contrário, uso todos os núcleos.
: "${MAKEFLAGS:=-j$(nproc)}"
export MAKEFLAGS

############################################
# Mensagem de aviso                        #
############################################

echo "[highperf.profile] ATENÇÃO: usando flags agressivas (O3, march=native, LTO)." >&2
echo "[highperf.profile] Alguns pacotes podem falhar ou ficar instáveis." >&2
