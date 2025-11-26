# Binutils-2.45.1 - Pass 1 (cross-toolchain)
# LFS r12.4.46 - Capítulo 5.2
# https://www.linuxfromscratch.org/lfs/view/development/chapter05/binutils-pass1.html

PKG_NAME="binutils-pass1"
PKG_VERSION="2.45.1"
PKG_RELEASE="1"
PKG_DESC="GNU Binutils (Passo 1 do toolchain cruzado)"
PKG_GROUPS="cross-toolchain"

# Para o Pass 1, não há dependências explícitas além do ambiente LFS/LFS_TGT já preparado
PKG_DEPENDS=""

PKG_URL="https://www.gnu.org/software/binutils/"
PKG_LICENSE="GPL-3+ e outras licenças GNU associadas"

# LFS usa este tarball e checksum:
# Download: https://sourceware.org/pub/binutils/releases/binutils-2.45.1.tar.xz
# MD5: ff59f8dc1431edfa54a257851bea74e7
PKG_SOURCES="https://sourceware.org/pub/binutils/releases/binutils-${PKG_VERSION}.tar.xz"
PKG_MD5SUM="ff59f8dc1431edfa54a257851bea74e7"

# --------------------------------------------------------------------
# IMPORTANTE:
#  - Esta recipe assume que as variáveis de ambiente LFS e LFS_TGT
#    já estão exportadas (como no livro LFS).
#  - O adm vai extrair o binutils-2.45.1 em $builddir/binutils-2.45.1
#    e chamar pkg_build/pkg_install a partir desse diretório.
#  - No LFS, instala-se em $LFS/tools; aqui fazemos isso via DESTDIR,
#    para que o pacote do adm instale sob ${LFS}/tools quando extraído.
# --------------------------------------------------------------------

pkg_prepare() {
  : "${LFS:?Variável LFS não definida. Exporte LFS antes de construir $PKG_NAME}"
  : "${LFS_TGT:?Variável LFS_TGT não definida. Exporte LFS_TGT antes de construir $PKG_NAME}"

  # Nada específico além da checagem de ambiente
  :
}

pkg_build() {
  : "${LFS:?Variável LFS não definida. Exporte LFS antes de construir $PKG_NAME}"
  : "${LFS_TGT:?Variável LFS_TGT não definida. Exporte LFS_TGT antes de construir $PKG_NAME}"

  # Estamos em $srcdir = binutils-2.45.1 (o adm já fez cd pra cá)
  mkdir -v build
  cd build

  ../configure --prefix=/tools       \
               --with-sysroot="$LFS" \
               --target="$LFS_TGT"   \
               --disable-nls         \
               --enable-gprofng=no   \
               --disable-werror      \
               --enable-new-dtags    \
               --enable-default-hash-style=gnu

  # Compilar Binutils Pass 1
  make
}

pkg_check() {
  # LFS não roda testes em Binutils Pass 1
  :
}

pkg_install() {
  : "${LFS:?Variável LFS não definida. Exporte LFS antes de construir $PKG_NAME}"

  # Ainda em binutils-2.45.1/build
  #
  # Livro manda: make install           (instalando em $LFS/tools)
  # Aqui: usamos DESTDIR para encaixar no esquema de pacotes do adm.
  #
  # Resultado final depois de empacotar + instalar via adm:
  #   ${LFS}/tools/bin, ${LFS}/tools/lib, etc.
  make DESTDIR="${PKG_DESTDIR}${LFS}" install
}

# Versão upstream para o mecanismo de upgrade do adm.
# Para toolchain cross, é mais seguro manter fixo.
pkg_upstream_version() {
  printf '%s\n' "${PKG_VERSION}"
}
