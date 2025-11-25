# Recipe para adm: Glibc-2.42
# Caminho sugerido: /var/lib/adm/recipes/core/glibc/glibc.sh

PKG_NAME="glibc"
PKG_VERSION="2.42"
PKG_RELEASE="1"

PKG_DESC="Biblioteca C principal do sistema (GNU C Library)"
PKG_URL="https://www.gnu.org/software/libc/"
PKG_LICENSE="LGPL-2.1-or-later"
# glibc faz parte do toolchain central
PKG_GROUPS="core toolchain"

# Fontes conforme LFS 12.4 (r12.4-46)
# Tarball principal + patches oficiais do LFS
PKG_SOURCES="
https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4/glibc-2.42.tar.xz
https://www.linuxfromscratch.org/patches/lfs/development/glibc-2.42-upstream_fixes-1.patch
https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4/glibc-2.42-fhs-1.patch
"

# Checksums:
# - glibc-2.42.tar.xz:
#     MD5  : 23c6f5a27932b435cae94e087cb8b1f5 (LFS packages md5sums)
#     SHA256: d1775e32e4628e64ef930f435b67bb63af7599acb6be2b335b9f19f16509f17f (Ubuntu orig tarball)
# - glibc-2.42-upstream_fixes-1.patch:
#     MD5  : fb47fb9c2732d3c8029bf6be48cd9ea4
# - glibc-2.42-fhs-1.patch:
#     MD5  : 9a5997c3452909b1769918c759eff8a2
PKG_MD5S="
23c6f5a27932b435cae94e087cb8b1f5
fb47fb9c2732d3c8029bf6be48cd9ea4
9a5997c3452909b1769918c759eff8a2
"

# Só temos SHA256 confiável do tarball principal.
# Para os patches, deixe a string vazia para o código do adm ignorar SHA nesse item.
PKG_SHA256S="
d1775e32e4628e64ef930f435b67bb63af7599acb6be2b335b9f19f16509f17f

"

# Tecnicamente glibc precisa dos headers do kernel já instalados,
# mas isso faz parte da sequência do LFS, não de dependência de runtime.
PKG_DEPENDS=""

pkg_prepare() {
  # Estamos no diretório de origem glibc-2.42

  # 1) Patch de upstream fixes (LFS 8.5.1)
  patch -Np1 -i ../glibc-2.42-upstream_fixes-1.patch

  # 2) Patch FHS para usar diretórios em conformidade com o FHS (var em vez de /var/db, etc.)
  patch -Np1 -i ../glibc-2.42-fhs-1.patch

  # 3) Correção do abort.c para não quebrar Valgrind em BLFS (sed do livro)
  sed -e '/unistd.h/i #include <string.h>' \
      -e '/libc_rwlock_init/c\
  __libc_rwlock_define_initialized (, reset_lock);\
  memcpy (&lock, &reset_lock, sizeof (lock));' \
      -i stdlib/abort.c

  # Diretório de build separado, como recomendado pela documentação da glibc
  mkdir -v build
}

pkg_build() {
  # Entrar no build dir criado em pkg_prepare
  cd build

  # Garantir que ldconfig e sln sejam instalados em /usr/sbin
  echo "rootsbindir=/usr/sbin" > configparms

  # Configuração conforme LFS:
  #  --disable-werror                (evita falha de testes por warnings)
  #  --disable-nscd                  (não construir nscd, obsoleto)
  #  libc_cv_slibdir=/usr/lib        (não usar /lib64)
  #  --enable-stack-protector=strong (proteção extra)
  #  --enable-kernel=5.4             (kernel mínimo suportado)
  ../configure --prefix=/usr                   \
               --disable-werror                \
               --disable-nscd                  \
               libc_cv_slibdir=/usr/lib        \
               --enable-stack-protector=strong \
               --enable-kernel=5.4

  # Compilar
  make

  # Testes – no livro são considerados críticos.
  # Se quiser pular, exporte ADM_SKIP_TESTS=1 antes de rodar o adm.
  if [[ "${ADM_SKIP_TESTS:-0}" != "1" ]]; then
    make check
  else
    echo "===> ADM_SKIP_TESTS=1 definido, pulando 'make check' para glibc."
  fi
}

pkg_install() {
  cd build

  # Instalar em DESTDIR para o adm empacotar depois
  make DESTDIR="${PKG_DESTDIR}" install

  # Ajustar ldd dentro do DESTDIR, não no sistema real
  if [[ -f "${PKG_DESTDIR}/usr/bin/ldd" ]]; then
    sed '/RTLDLIST=/s@/usr@@g' -i "${PKG_DESTDIR}/usr/bin/ldd"
  fi

  # IMPORTANTE:
  #  - Configuração de /etc/nsswitch.conf
  #  - Instalação de time zone data (tzdata2025b + zic)
  #  - /etc/localtime, /etc/ld.so.conf
  #
  # Esses passos estão em 8.5.2 do livro e são mais configuração de sistema
  # do que parte do pacote em si. Em um sistema gerenciado por 'adm' você
  # provavelmente vai querer tratar isso em recipes separadas (ex: tzdata)
  # ou em scripts de pós-instalação específicos, em vez de empacotar como
  # arquivos "pertencentes" ao pacote glibc.
}

# Versão mais recente de glibc no upstream
pkg_upstream_version() {
  local url="https://ftp.gnu.org/gnu/glibc/"
  local latest

  latest="$(
    curl -fsSL "$url" \
      | sed -n 's/.*glibc-\([0-9][0-9.]*\)\.tar\.xz.*/\1/p' \
      | sort -V \
      | tail -n1
  )"

  if [[ -n "$latest" ]]; then
    printf '%s\n' "$latest"
  else
    # Fallback seguro: usar a versão da própria recipe
    printf '%s\n' "$PKG_VERSION"
  fi
}
