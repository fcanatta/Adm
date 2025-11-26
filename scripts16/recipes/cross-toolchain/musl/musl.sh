#!/usr/bin/env bash
# musl-1.2.5 (cross-toolchain) com patches da CVE-2025-26519
#
# Patches oficiais:
#   https://www.openwall.com/lists/musl/2025/02/13/1/1
#   https://www.openwall.com/lists/musl/2025/02/13/1/2
#
# Os dois patches corrigem um bug de segurança no iconv()
# (CVE-2025-26519), recomendação do próprio Rich Felker:
#   https://www.openwall.com/lists/musl/2025/05/29/2

PKG_NAME="musl"
PKG_VERSION="1.2.5"
PKG_RELEASE="1"

PKG_DESC="musl libc ${PKG_VERSION} - libc alternativa para ambiente cross-toolchain"
PKG_LICENSE="MIT"
PKG_URL="https://musl.libc.org/"
# Deixa separado do toolchain glibc. Troque para 'cross-toolchain'
# se quiser que entre no mesmo grupo.
PKG_GROUPS="cross-toolchain-musl"

# Dependências lógicas: precisa de toolchain básico e linux-headers
PKG_DEPENDS="binutils-pass1 gcc-pass1 linux-headers"

# Fonte principal do musl
PKG_SOURCES="https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"

# SHA256 oficial do tarball do musl-1.2.5
# (verificado em múltiplas fontes)
#   a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4
PKG_SHA256SUM="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

# URLs dos patches de segurança (não entram em PKG_SOURCES para
# não quebrar a verificação de hash única do adm)
MUSL_PATCH1_URL="https://www.openwall.com/lists/musl/2025/02/13/1/1"
MUSL_PATCH2_URL="https://www.openwall.com/lists/musl/2025/02/13/1/2"

# Cross-toolchain: não queremos upgrades automáticos
pkg_upstream_version() {
  printf '%s\n' "$PKG_VERSION"
}

# -------------------------------------------------------------
# prepare(): checa ambiente e baixa / prepara os patches
# -------------------------------------------------------------
pkg_prepare() {
  : "${LFS:?Variável LFS não definida. Exporte LFS=/mnt/lfs (por exemplo)}"
  : "${LFS_TGT:?Variável LFS_TGT não definida. Ex: x86_64-lfs-linux-gnu}"
  : "${ADM_SRC_CACHE:?ADM_SRC_CACHE não definido (diretório de cache de fontes do adm)}"

  # Baixa os patches para arquivos com nomes decentes no cache
  local patch1 patch2
  patch1="${ADM_SRC_CACHE}/musl-${PKG_VERSION}-CVE-2025-26519-1.patch"
  patch2="${ADM_SRC_CACHE}/musl-${PKG_VERSION}-CVE-2025-26519-2.patch"

  # download_one() é função interna do adm, já usada em download_sources_parallel
  download_one "$MUSL_PATCH1_URL" "$patch1"
  download_one "$MUSL_PATCH2_URL" "$patch2"

  # Aplica os patches dentro do source tree do musl
  # O adm já deu "cd" para o diretório do tarball (musl-1.2.5)
  patch -Np1 -i "$patch1"
  patch -Np1 -i "$patch2"
}

# -------------------------------------------------------------
# build():
#   - constrói em diretório separado "build/"
#   - usa o cross-compiler $LFS_TGT-gcc
#   - prefix=/usr e syslibdir=/lib (como recomendado quando musl é
#     libc “de sistema”; DESTDIR aponta para $LFS)
# -------------------------------------------------------------
pkg_build() {
  : "${LFS:?Variável LFS não definida}"
  : "${LFS_TGT:?Variável LFS_TGT não definida}"

  mkdir -v build
  cd       build

  # Garante que o cross-compiler do toolchain seja usado
  CC="${LFS_TGT}-gcc" \
  ../configure \
      --prefix=/usr \
      --syslibdir=/lib \
      --target="${LFS_TGT}"

  # Compila o musl
  make

  # volta para o diretório do source para o install()
  cd ..
}

# -------------------------------------------------------------
# check():
#   O musl não tem suíte de testes "plug and play" como a glibc
#   aqui. Se você quiser, pode rodar alguns binários de teste
#   manualmente depois da instalação.
# -------------------------------------------------------------
pkg_check() {
  :
}

# -------------------------------------------------------------
# install():
#   - make DESTDIR=$LFS install
#   Adaptado ao adm:
#     DESTDIR = ${PKG_DESTDIR}${LFS}
#
#   Resultado final (dentro do staging):
#     ${PKG_DESTDIR}${LFS}/usr/include/...
#     ${PKG_DESTDIR}${LFS}/lib/ld-musl-*.so.1
#     ${PKG_DESTDIR}${LFS}/lib/libc.so
#     etc.
# -------------------------------------------------------------
pkg_install() {
  : "${LFS:?Variável LFS não definida}"
  : "${PKG_DESTDIR:?PKG_DESTDIR não definido}"

  cd build

  # Instala dentro do staging do adm, com sysroot em $LFS
  make DESTDIR="${PKG_DESTDIR}${LFS}" install

  cd ..
}
