# profile-glibc.sh
# Ambiente para construir um sistema baseado em glibc usando o admV2.
# Use com:  source /caminho/para/profile-glibc.sh

# Garante que está sendo "sourced", não executado
# (se estiver sendo executado, 'return' dá erro e caímos no exit)
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
    *":$dir:"*) ;;          # já está
    *) PATH="$dir:$PATH" ;; # adiciona no começo
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

_default_glibc_triplet() {
  local arch
  arch="$(_detect_arch)"
  case "$arch" in
    x86_64)  echo x86_64-pc-linux-gnu ;;
    i686)    echo i686-pc-linux-gnu ;;
    aarch64) echo aarch64-unknown-linux-gnu ;;
    armv7l)  echo armv7l-unknown-linux-gnueabihf ;;
    *)       echo "${arch}-unknown-linux-gnu" ;;
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

# Onde está a árvore do admV2 (scripts, db, cache, etc.)
# Se já estiver definida fora, não mexe.
: "${ADM_ROOT:=/mnt/adm}"

# Root do sistema glibc que você está construindo.
# Exemplo: /opt/systems/glibc-root
: "${ADM_ROOTFS:=/opt/systems/glibc-root}"

# Normaliza ADM_ROOTFS (tira barra final, exceto se for "/" mesmo)
case "$ADM_ROOTFS" in
  /) ;;
  */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
esac

export ADM_ROOT ADM_ROOTFS

# ---------- Perfil / toolchain ----------

# Perfil de libc que o admV2 usa internamente
export PROFILE="glibc"

# Triplet alvo (host) para os pacotes.
# Se já veio de fora, não mexe; senão define um padrão baseado na arquitetura.
if [[ -z "${TARGET_TRIPLET:-}" ]]; then
  export TARGET_TRIPLET="$(_default_glibc_triplet)"
fi

# Em builds "normais", HOST = TARGET_TRIPLET
if [[ -z "${HOST:-}" ]]; then
  export HOST="$TARGET_TRIPLET"
fi

# Tenta localizar toolchain específica primeiro, antes dos genéricos.
# Ajuste estes caminhos conforme onde você instalou seu toolchain glibc:
_prepend_path "/opt/toolchains/glibc/bin"
_prepend_path "/usr/local/glibc-toolchain/bin"

# Compiladores e binutils:
if [[ -z "${CC:-}" ]]; then
  if command -v "${TARGET_TRIPLET}-gcc" >/dev/null 2>&1; then
    export CC="${TARGET_TRIPLET}-gcc"
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

# Número de jobs paralelos para make
if [[ -z "${NUMJOBS:-}" ]]; then
  export NUMJOBS="$(_detect_nproc)"
fi

# MAKEFLAGS padrão, se não definido
if [[ -z "${MAKEFLAGS:-}" ]]; then
  export MAKEFLAGS="-j${NUMJOBS}"
fi

# CFLAGS e CXXFLAGS padrão (podem ser sobrescritos fora)
if [[ -z "${CFLAGS:-}" ]]; then
  CFLAGS="-O2 -pipe"
  # Se quiser ativar -march=native, defina USE_MARCH_NATIVE=1 antes de dar source
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

# PKG_CONFIG para enxergar libs instaladas dentro do root do sistema
# (mais útil se você compilar fora de chroot, apontando para ADM_ROOTFS)
if [[ -z "${PKG_CONFIG_LIBDIR:-}" ]]; then
  export PKG_CONFIG_LIBDIR="${ADM_ROOTFS}/usr/lib/pkgconfig:${ADM_ROOTFS}/usr/share/pkgconfig:${ADM_ROOTFS}/usr/lib64/pkgconfig"
fi

# ---------- Mensagem resumo ----------

echo "========================================"
echo " Ambiente glibc para admV2 configurado"
echo "  ADM_ROOT   = ${ADM_ROOT}"
echo "  ADM_ROOTFS = ${ADM_ROOTFS}"
echo "  PROFILE    = ${PROFILE}"
echo "  HOST       = ${HOST}"
echo "  TARGET     = ${TARGET_TRIPLET}"
echo "  CC         = ${CC}"
echo "  NUMJOBS    = ${NUMJOBS}"
echo "========================================"
