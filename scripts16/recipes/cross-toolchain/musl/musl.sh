# Recipe para adm: musl-1.2.5 (cross-toolchain, com patches CVE-2025-26519)
#
# - libc alvo: musl 1.2.5
# - instalação: sysroot do cross-toolchain (ADM_CROSS_SYSROOT ou LFS)
# - patches: dois patches oficiais do Rich Felker publicados na Openwall
#   para corrigir CVE-2025-26519 na implementação de iconv (EUC-KR + UTF-8) 1
#
# Documentação musl:
#   - site:      https://musl.libc.org/
#   - releases:  https://musl.libc.org/releases/musl-1.2.5.tar.gz 2
#   - getting started / build: https://wiki.musl-libc.org/getting-started.html 3

PKG_NAME="musl"
PKG_VERSION="1.2.5"
PKG_RELEASE="1"

PKG_DESC="musl libc ${PKG_VERSION} para o sysroot do cross-toolchain (com patches CVE-2025-26519)"
PKG_URL="https://musl.libc.org/"
PKG_LICENSE="MIT"
PKG_GROUPS="cross-toolchain-musl"

# Fonte principal: tarball oficial
PKG_SOURCES="https://musl.libc.org/releases/musl-1.2.5.tar.gz"

# Checksums do tarball:
#   - MD5:   ac5cfde7718d0547e224247ccfe59f18   4
#   - SHA256 a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4 5
PKG_MD5S="ac5cfde7718d0547e224247ccfe59f18"
PKG_SHA256S="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

# Patches CVE-2025-26519:
#   1) iconv: fix erroneous input validation in EUC-KR decoder     (e5adcd97...) 6
#   2) iconv: harden UTF-8 output code path against decoder bugs   (c47ad25e...) 7
#
# Eles serão baixados em pkg_prepare() para o cache de fontes.
MUSL_PATCH1_URL="https://www.openwall.com/lists/musl/2025/02/13/1/1"
MUSL_PATCH2_URL="https://www.openwall.com/lists/musl/2025/02/13/1/2"

# Dependências lógicas:
# - precisa do toolchain cross já montado (gcc-pass1 + binutils-pass1)
# - precisa dos headers do kernel no sysroot
PKG_DEPENDS="linux-headers gcc-pass1 binutils-pass1"

pkg_prepare() {
  # Estamos dentro de musl-1.2.5 (pasta do tarball extraído)
  local src_cache="${ADM_SRC_CACHE:-/var/cache/adm/src}"

  mkdir -pv "${src_cache}"

  # Arquivos locais para os patches
  local p1="${src_cache}/musl-1.2.5-CVE-2025-26519-1-euckr.patch"
  local p2="${src_cache}/musl-1.2.5-CVE-2025-26519-2-utf8-harden.patch"

  # Baixa os patches da Openwall se ainda não existirem no cache
  if [[ ! -s "$p1" ]]; then
    echo "===> Baixando patch CVE-2025-26519 #1 (EUC-KR) para musl-1.2.5..."
    curl -fsSLo "$p1" "$MUSL_PATCH1_URL" \
      || die "Falha ao baixar patch 1 de ${MUSL_PATCH1_URL}"
  fi

  if [[ ! -s "$p2" ]]; then
    echo "===> Baixando patch CVE-2025-26519 #2 (UTF-8 hardening) para musl-1.2.5..."
    curl -fsSLo "$p2" "$MUSL_PATCH2_URL" \
      || die "Falha ao baixar patch 2 de ${MUSL_PATCH2_URL}"
  fi

  # Aplica os patches (ambos mexem em src/locale/iconv.c)
  echo "===> Aplicando patch 1 (EUC-KR decoder) em src/locale/iconv.c..."
  patch -Np1 -i "$p1"

  echo "===> Aplicando patch 2 (UTF-8 output hardening) em src/locale/iconv.c..."
  patch -Np1 -i "$p2"

  # Podemos construir no próprio source tree do musl,
  # mas pra ficar consistente com o resto do adm, usamos build/ separado.
  mkdir -v build
}

pkg_build() {
  cd build

  # Raiz do toolchain (onde estão $TARGET-gcc, $TARGET-ld, etc.)
  local cross_root="${ADM_CROSS_ROOT:-/usr/src/cross-toolchain}"

  # Sysroot do alvo (equivalente ao $LFS nos passos com glibc):
  #   - ADM_CROSS_SYSROOT: preferido
  #   - LFS: fallback
  #   - /mnt/lfs: fallback final
  local sysroot="${ADM_CROSS_SYSROOT:-${LFS:-/mnt/lfs}}"

  # Triplet musl alvo, ex: x86_64-linux-musl, arm-linux-musleabihf, etc. 8
  local tgt="${ADM_MUSL_TARGET:-${ADM_CROSS_TARGET:-${LFS_TGT:-}}}"
  if [[ -z "$tgt" ]]; then
    die "Defina ADM_MUSL_TARGET ou ADM_CROSS_TARGET (ex: x86_64-linux-musl) antes de construir musl."
  fi

  # TOOLCHAIN no PATH: garante que configure/make usem o cross binutils+gcc corretos
  PATH="${cross_root}/bin:${PATH}"
  export PATH

  # Configure padrão do musl para cross, instalando em /usr dentro do sysroot:
  #
  #   ./configure \
  #     --prefix=/usr \
  #     --target=$tgt \
  #     --host=$tgt \
  #     --syslibdir=/lib
  #
  # O DESTDIR no pkg_install() vai empurrar isso para $sysroot.
  ../configure \
    --prefix=/usr        \
    --target="${tgt}"    \
    --host="${tgt}"      \
    --syslibdir=/lib

  # Compila musl (é rápido)
  make
}

pkg_install() {
  cd build

  local sysroot="${ADM_CROSS_SYSROOT:-${LFS:-/mnt/lfs}}"

  # Instala dentro do sysroot do alvo, via DESTDIR do adm:
  #
  #   make DESTDIR="$sysroot" install
  #
  # Aqui adaptado para PKG_DESTDIR + sysroot, pra virar pacote binário limpo.
  local dest="${PKG_DESTDIR}${sysroot}"

  echo "===> Instalando musl ${PKG_VERSION} em sysroot: ${dest}"
  make DESTDIR="${dest}" install

  # Opcionalmente, poderíamos ajustar algo aqui (ld-musl-*.so.1 etc).
  # Na maioria dos casos o padrão do musl (syslibdir=/lib) já é o desejado,
  # então deixamos como está.
}

pkg_upstream_version() {
  # Descobre a última versão "musl-x.y.z.tar.gz" na página de releases.
  # Se falhar (sem rede, formato mudou, etc), volta PKG_VERSION.
  local url="https://musl.libc.org/releases/"
  local latest=""

  if command -v curl >/dev/null 2>&1; then
    latest="$(
      curl -fsSL "$url" \
        | sed -n 's/.*musl-\([0-9][0-9.]*\)\.tar\.gz.*/\1/p' \
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
