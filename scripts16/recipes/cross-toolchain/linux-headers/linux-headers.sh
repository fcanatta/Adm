# Recipe para adm: Linux-6.17.8 API Headers
# Linux From Scratch - Version r12.4-46, seção 5.4 (Linux-6.17.8 API Headers)

PKG_NAME="linux-headers"
PKG_VERSION="6.17.8"
PKG_RELEASE="1"

PKG_DESC="Linux ${PKG_VERSION} API Headers para o toolchain (expostos em /usr/include)"
PKG_URL="https://www.kernel.org/"
PKG_LICENSE="GPL-2.0-only"
PKG_GROUPS="cross-toolchain cross-toolchain-musl"

# Fonte conforme capítulo 3.2 (All Packages)
# Linux (6.17.8) - Download + MD5
PKG_SOURCES="https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.17.8.tar.xz"
PKG_MD5S="74c34fafb5914d05447863cdc304ab55"
PKG_SHA256S=""

# Ordem lógica dentro do cross-toolchain:
# No livro a sequência é Binutils-pass1 -> GCC-pass1 -> Linux headers -> Glibc.
# Aqui fazemos linux-headers depender de gcc-pass1 para manter essa ordem.
PKG_DEPENDS="gcc-pass1"

pkg_prepare() {
  # 5.4.1: garantir que não há arquivos velhos no tarball
  # make mrproper
  make mrproper
}

pkg_build() {
  # 5.4.1: extrair os headers "user-visible" para ./usr
  # make headers
  make headers

  # Remover tudo que não for arquivo .h em usr/include
  # find usr/include -type f ! -name '*.h' -delete
  find usr/include -type f ! -name '*.h' -delete
}

pkg_install() {
  # No LFS: cp -rv usr/include $LFS/usr
  # Aqui adaptamos para um sysroot configurável:
  #
  #   - ADM_CROSS_SYSROOT: preferido (ex: /mnt/lfs)
  #   - LFS: fallback, como no livro
  #   - /mnt/lfs: fallback final, se nada estiver definido
  #
  local cross_sysroot="${ADM_CROSS_SYSROOT:-${LFS:-/mnt/lfs}}"

  # Instalar os headers em:
  #   <sysroot>/usr/include
  #
  # via PKG_DESTDIR, para o adm empacotar e depois instalar no sistema real.
  local destdir="${PKG_DESTDIR}${cross_sysroot}/usr"

  mkdir -pv "${destdir}"

  # Copia a árvore usr/include gerada pelo make headers
  cp -rv usr/include "${destdir}/"
}

pkg_upstream_version() {
  # Pega a última versão linux-6.* disponível em kernel.org (série 6.x).
  # Se der erro de rede, volta pra versão da própria recipe.
  local url="https://www.kernel.org/pub/linux/kernel/v6.x/"
  local latest=""

  if command -v curl >/dev/null 2>&1; then
    latest="$(
      curl -fsSL "$url" \
        | sed -n 's/.*linux-\(6\.[0-9.]*\)\.tar\.xz.*/\1/p' \
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
