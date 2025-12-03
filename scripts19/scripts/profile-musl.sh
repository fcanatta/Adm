# profile-musl.sh
# Ambiente para construir um sistema baseado em musl usando o admV2.
# Use com:  source /caminho/para/profile-musl.sh

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Este script deve ser usado com 'source', não executado diretamente."
  echo "Exemplo:  source ${0}"
  exit 1
fi

# ---------- Helpers genéricos ----------

_prepend_path() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
}

_detect_arch() {
  local arch
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$arch" in
    x86_64) echo x86_64 ;;
    i?86)   echo i686   ;;
    aarch64) echo aarch64 ;;
    armv7l|armv7hl) echo armv7l ;;
    *) echo "$arch" ;;
  esac
}

_default_musl_triplet() {
  local arch
  arch="$(_detect_arch)"
  case "$arch" in
    x86_64)  echo x86_64-linux-musl ;;
    i686)    echo i686-linux-musl ;;
    aarch64) echo aarch64-linux-musl ;;
    armv7l)  echo armv7l-linux-musleabihf ;;
    *)       echo "${arch}-linux-musl" ;;
  esac
}

_detect_nproc() {
  local n
  if command -v nproc >/dev/null 2>&1; then
    n="$(nproc)"
  elif command -v getconf >/dev/null 2>&1; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  else
    n=1
  fi
  echo "${n:-1}"
}

# ---------- ADM & rootfs ----------

: "${ADM_ROOT:=/mnt/adm}"
: "${ADM_ROOTFS:=/opt/systems/musl-root}"

case "$ADM_ROOTFS" in
  /) ;;
  */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
esac

export ADM_ROOT ADM_ROOTFS

# ---------- Perfil / toolchain ----------

export PROFILE="musl"

if [[ -z "${TARGET_TRIPLET:-}" ]]; then
  export TARGET_TRIPLET="$(_default_musl_triplet)"
fi

if [[ -z "${HOST:-}" ]]; then
  export HOST="$TARGET_TRIPLET"
fi

# Caminhos típicos de toolchain musl (ajuste se você usa outro layout)
_prepend_path "/opt/toolchains/musl/bin"
_prepend_path "/usr/local/musl-toolchain/bin"

# Para musl, preferimos um dos seguintes, nessa ordem:
#   1) ${TARGET_TRIPLET}-gcc
#   2) ${TARGET_TRIPLET}-musl-gcc
#   3) musl-gcc
#   4) gcc (fallback)
if [[ -z "${CC:-}" ]]; then
  if command -v "${TARGET_TRIPLET}-gcc" >/dev/null 2>&1; then
    export CC="${TARGET_TRIPLET}-gcc"
  elif command -v "${TARGET_TRIPLET}-musl-gcc" >/dev/null 2>&1; then
    export CC="${TARGET_TRIPLET}-musl-gcc"
  elif command -v musl-gcc >/dev/null 2>&1; then
    export CC="musl-gcc"
  else
    export CC="gcc"
  fi
fi

if [[ -z "${CXX:-}" ]]; then
  if command -v "${TARGET_TRIPLET}-g++" >/dev/null 2>&1; then
    export CXX="${TARGET_TRIPLET}-g++"
  else
    export CXX="g++"
  fi
fi

if [[ -z "${AR:-}" ]]; then
  if command -v "${TARGET_TRIPLET}-ar" >/dev/null 2>&1; then
    export AR="${TARGET_TRIPLET}-ar"
  else
    export AR="ar"
  fi
fi

if [[ -z "${RANLIB:-}" ]]; then
  if command -v "${TARGET_TRIPLET}-ranlib" >/dev/null 2>&1; then
    export RANLIB="${TARGET_TRIPLET}-ranlib"
  else
    export RANLIB="ranlib"
  fi
fi

if [[ -z "${LD:-}" ]]; then
  if command -v "${TARGET_TRIPLET}-ld" >/dev/null 2>&1; then
    export LD="${TARGET_TRIPLET}-ld"
  fi
fi

if [[ -z "${STRIP:-}" ]]; then
  if command -v "${TARGET_TRIPLET}-strip" >/dev/null 2>&1; then
    export STRIP="${TARGET_TRIPLET}-strip"
  else
    export STRIP="strip"
  fi
fi

# ---------- Otimizações de compilação ----------

if [[ -z "${NUMJOBS:-}" ]]; then
  export NUMJOBS="$(_detect_nproc)"
fi

if [[ -z "${MAKEFLAGS:-}" ]]; then
  export MAKEFLAGS="-j${NUMJOBS}"
fi

if [[ -z "${CFLAGS:-}" ]]; then
  CFLAGS="-O2 -pipe"
  if [[ "${USE_MARCH_NATIVE:-0}" = "1" ]]; then
    CFLAGS="$CFLAGS -march=native"
  fi
  export CFLAGS
fi

if [[ -z "${CXXFLAGS:-}" ]]; then
  CXXFLAGS="-O2 -pipe"
  if [[ "${USE_MARCH_NATIVE:-0}" = "1" ]]; then
    CXXFLAGS="$CXXFLAGS -march=native"
  fi
  export CXXFLAGS
fi

if [[ -z "${PKG_CONFIG_LIBDIR:-}" ]]; then
  export PKG_CONFIG_LIBDIR="${ADM_ROOTFS}/usr/lib/pkgconfig:${ADM_ROOTFS}/usr/share/pkgconfig:${ADM_ROOTFS}/usr/lib64/pkgconfig"
fi

# ---------- Mensagem resumo ----------

echo "========================================"
echo " Ambiente musl para admV2 configurado"
echo "  ADM_ROOT   = ${ADM_ROOT}"
echo "  ADM_ROOTFS = ${ADM_ROOTFS}"
echo "  PROFILE    = ${PROFILE}"
echo "  HOST       = ${HOST}"
echo "  TARGET     = ${TARGET_TRIPLET}"
echo "  CC         = ${CC}"
echo "  NUMJOBS    = ${NUMJOBS}"
echo "========================================"
