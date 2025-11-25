# Recipe para adm: man-pages-6.16
# Caminho sugerido: /var/lib/adm/recipes/man-pages.sh

PKG_NAME="man-pages"
PKG_VERSION="6.16"
PKG_GROUPS="core"
PKG_RELEASE="1"

PKG_DESC="Coleção de páginas de manual do projeto Linux man-pages"
PKG_URL="https://www.kernel.org/doc/man-pages/"
PKG_LICENSE="GPL-2.0-or-later"

# man-pages não precisa de deps especiais
PKG_DEPENDS=""

# Fonte conforme LFS
PKG_SOURCES="https://www.kernel.org/pub/linux/docs/man-pages/man-pages-6.16.tar.xz"

# Checksums alinhados com PKG_SOURCES
PKG_SHA256S="8e247abd75cd80809cfe08696c81b8c70690583b045749484b242fb43631d7a3"
PKG_MD5S="4394eac3258137c8b549febeb04a7c33"

pkg_prepare() {
  # LFS: remover páginas de crypt*, fornecidas por libxcrypt
  rm -v man3/crypt* || true
}

pkg_build() {
  # man-pages não precisa de build
  :
}

pkg_install() {
  # LFS: make -R GIT=false prefix=/usr install
  make -R \
       GIT=false \
       prefix="${PKG_PREFIX:-/usr}" \
       DESTDIR="${PKG_DESTDIR}" \
       install
}

# ----------- upgrade automático no upstream ------------

pkg_upstream_version() {
  # Usa a listagem HTML da kernel.org para achar o último man-pages-*.tar.xz
  # Requer: curl, sed, sort
  local url="https://www.kernel.org/pub/linux/docs/man-pages/"
  local latest
  latest="$(
    curl -fsSL "$url" \
    | sed -n 's/.*man-pages-\([0-9][0-9\.]*\)\.tar\.xz.*/\1/p' \
    | sort -V \
    | tail -n1
  )"

  if [[ -n "$latest" ]]; then
    printf '%s\n' "$latest"
  else
    # fallback: se der erro na rede/parse, volta pra própria versão
    printf '%s\n' "$PKG_VERSION"
  fi
}
