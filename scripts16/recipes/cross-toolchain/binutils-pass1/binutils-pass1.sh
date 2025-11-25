# Recipe para adm: Binutils-2.45.1 - Pass 1
# Linux From Scratch - Version r12.4-46, seção 5.2

PKG_NAME="binutils-pass1"
PKG_VERSION="2.45.1"
PKG_RELEASE="1"

PKG_DESC="Binutils (Passo 1 do cross-toolchain temporário)"
PKG_URL="https://www.gnu.org/software/binutils/"
PKG_LICENSE="GPL-3.0-or-later"
PKG_GROUPS="cross-toolchain cross-toolchain-musl"

# Fonte e MD5 conforme capítulo 3.2 (All Packages) do LFS r12.4-46
PKG_SOURCES="https://sourceware.org/pub/binutils/releases/binutils-2.45.1.tar.xz"
PKG_MD5S="ff59f8dc1431edfa54a257851bea74e7"
PKG_SHA256S=""

# Primeiro pacote do cross-toolchain: sem dependências explícitas aqui
PKG_DEPENDS=""

# ============================================
#  Pass 1 do Binutils (cross)
#  Instalar tudo sob /usr/src/cross-toolchain
# ============================================

pkg_prepare() {
  # Nada especial além do diretório de build recomendado
  mkdir -v build
}

pkg_build() {
  cd build

  # Raiz onde TODO o cross-toolchain vai morar
  # Você pode sobrescrever com: ADM_CROSS_ROOT=/algum/lugar adm build binutils-pass1
  local cross_root="${ADM_CROSS_ROOT:-/usr/src/cross-toolchain}"

  # Sysroot do cross; se não quiser separar, usa o próprio cross_root
  local cross_sysroot="${ADM_CROSS_SYSROOT:-$cross_root}"

  # Target do LFS (ex: x86_64-lfs-linux-gnu) – tem que vir de fora
  local tgt="${ADM_CROSS_TARGET:-${LFS_TGT:-}}"
  if [[ -z "$tgt" ]]; then
    die "Defina ADM_CROSS_TARGET ou LFS_TGT com o triplet alvo (ex: x86_64-lfs-linux-gnu) antes de construir binutils-pass1."
  fi

  ../configure \
    --prefix="${cross_root}" \
    --with-sysroot="${cross_sysroot}" \
    --target="${tgt}" \
    --disable-nls \
    --enable-gprofng=no \
    --disable-werror \
    --enable-new-dtags \
    --enable-default-hash-style=gnu

  make
}

pkg_install() {
  cd build

  # Instalando em DESTDIR para o adm empacotar. O prefix já aponta
  # para /usr/src/cross-toolchain, então o resultado final será
  # /usr/src/cross-toolchain/bin, /usr/src/cross-toolchain/lib, etc.
  make DESTDIR="${PKG_DESTDIR}" install
}

pkg_upstream_version() {
  # Procura a maior versão binutils-X.Y[.Z] no espelho oficial
  local url="https://sourceware.org/pub/binutils/releases/"
  local latest=""

  if command -v curl >/dev/null 2>&1; then
    latest="$(
      curl -fsSL "$url" \
        | sed -n 's/.*binutils-\([0-9][0-9.]*\)\.tar\.xz.*/\1/p' \
        | sort -V \
        | tail -n1
    )"
  fi

  if [[ -n "$latest" ]]; then
    printf '%s\n' "$latest"
  else
    printf '%s\n' "$PKG_VERSION"
  fi
}
