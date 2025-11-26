# Libstdc++ from GCC-15.2.0 (cross-toolchain)
# LFS r12.4-46 - Capítulo 5.6
# https://www.linuxfromscratch.org/lfs/view/development/chapter05/gcc-libstdc++.html

PKG_NAME="gcc-libstdc++"
PKG_VERSION="15.2.0"
PKG_RELEASE="1"
PKG_DESC="Libstdc++ (biblioteca padrão C++ do GCC) para o toolchain cruzado"
PKG_GROUPS="cross-toolchain"

# Ajuste os nomes dos deps para bater com os recipes que você já criou:
# - gcc-pass1: recipe do GCC pass 1 (cross)
# - glibc: recipe da Glibc do capítulo 5
# - linux-headers: recipe dos headers 6.17.8
PKG_DEPENDS="gcc-pass1 glibc linux-headers"

PKG_URL="https://gcc.gnu.org/"
PKG_LICENSE="GPL-3+ e licença de runtime para libstdc++"

# LFS usa o tarball oficial do GCC; Libstdc++ vem de dentro dele
PKG_SOURCES="https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"

# SHA256 do gcc-15.2.0.tar.xz (conforme FreeBSD/Fossies)
# SHA256 (gcc-15.2.0.tar.xz) = 438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e
PKG_SHA256SUM="438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e"

# --------------------------------------------------------------------
# IMPORTANTE:
#  - Esta recipe assume que as variáveis de ambiente LFS e LFS_TGT
#    já estão exportadas (como no livro LFS).
#  - O adm vai extrair o gcc-15.2.0 em $builddir/gcc-15.2.0
#    e chamar pkg_build/pkg_install a partir desse diretório.
# --------------------------------------------------------------------

pkg_prepare() {
  : "${LFS:?Variável LFS não definida. Exporte LFS antes de construir $PKG_NAME}"
  : "${LFS_TGT:?Variável LFS_TGT não definida. Exporte LFS_TGT antes de construir $PKG_NAME}"

  # Nada específico aqui; o capítulo só manda criar o build dir dentro do src
  :
}

pkg_build() {
  : "${LFS:?Variável LFS não definida. Exporte LFS antes de construir $PKG_NAME}"
  : "${LFS_TGT:?Variável LFS_TGT não definida. Exporte LFS_TGT antes de construir $PKG_NAME}"

  # Estamos em $srcdir = gcc-15.2.0 (o adm já fez cd pra cá)
  mkdir -v build
  cd build

  ../libstdc++-v3/configure      \
      --host="$LFS_TGT"          \
      --build="$(../config.guess)" \
      --prefix=/usr              \
      --disable-multilib         \
      --disable-nls              \
      --disable-libstdcxx-pch    \
      --with-gxx-include-dir=/tools/"$LFS_TGT"/include/c++/"$PKG_VERSION"

  # Compilar libstdc++
  make
}

pkg_check() {
  # O livro não manda rodar testes aqui; deixamos vazio
  :
}

pkg_install() {
  : "${LFS:?Variável LFS não definida. Exporte LFS antes de construir $PKG_NAME}"

  # Estamos ainda em gcc-15.2.0/build
  # O LFS manda: make DESTDIR=$LFS install
  # Aqui encaixamos isso dentro do DESTDIR do adm:
  #
  #   PKG_DESTDIR   -> raiz de staging do adm
  #   PKG_DESTDIR$LFS -> onde o LFS deseja que os arquivos apareçam
  #
  # Resultado final após empacotar + instalar:
  #   /mnt/lfs/usr/... etc (ou o valor que você tiver em $LFS)
  make DESTDIR="${PKG_DESTDIR}${LFS}" install

  # Remover arquivos .la como o livro manda:
  #   rm -v $LFS/usr/lib/lib{stdc++{,exp,fs},supc++}.la
  rm -v "${PKG_DESTDIR}${LFS}"/usr/lib/lib{stdc++{,exp,fs},supc++}.la 2>/dev/null || true
}

# Versão upstream para o mecanismo de upgrade do adm
pkg_upstream_version() {
  printf '%s\n' "${PKG_VERSION}"
}
