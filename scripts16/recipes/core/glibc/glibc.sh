# Recipe para adm: Glibc-2.42
# Segue o LFS 12.4 (systemd) seção 8.5 0

PKG_NAME="glibc"
PKG_VERSION="2.42"
PKG_RELEASE="1"

PKG_DESC="Biblioteca C principal do sistema (GNU C Library)"
PKG_URL="https://www.gnu.org/software/libc/"
PKG_LICENSE="LGPL-2.1-or-later"
PKG_GROUPS="core toolchain"

# Fontes:
#  - Tarball oficial GNU
#  - Patch upstream_fixes do LFS
#  - Patch FHS do LFS
PKG_SOURCES="
https://ftp.gnu.org/gnu/glibc/glibc-2.42.tar.xz
https://www.linuxfromscratch.org/patches/lfs/development/glibc-2.42-upstream_fixes-1.patch
https://www.linuxfromscratch.org/patches/lfs/development/glibc-2.42-fhs-1.patch
"

# MD5 de cada fonte (mesma ordem de PKG_SOURCES)
# - tarball: da página de pacotes do LFS 12.4 1
# - patches: da página de patches LFS/development 2
PKG_MD5S="
23c6f5a27932b435cae94e087cb8b1f5
fb47fb9c2732d3c8029bf6be48cd9ea4
9a5997c3452909b1769918c759eff8a2
"

# IMPORTANTE:
# Do jeito que o adm foi escrito, ou a gente:
#   - fornece SHA256 pra TODOS os sources
#   - ou deixa SEM SHA256
# Como só temos SHA256 confiável pro tarball principal e não pros patches,
# aqui deixo PKG_SHA256S vazio -> só MD5 será usado.
PKG_SHA256S=""

# Dependências de ordem (não é hard runtime, mas ajuda a seguir a ordem do livro):
# LFS instala Iana-Etc antes do Glibc 3
PKG_DEPENDS="iana-etc"

pkg_prepare() {
  # Estamos dentro do diretório glibc-2.42
  # 1) patch upstream_fixes (LFS 8.5.1) 4
  patch -Np1 -i ../glibc-2.42-upstream_fixes-1.patch

  # 2) patch FHS para /var em vez de /var/db etc 5
  patch -Np1 -i ../glibc-2.42-fhs-1.patch

  # 3) correção do abort.c para não quebrar Valgrind em BLFS 6
  sed -e '/unistd.h/i #include <string.h>' \
      -e '/libc_rwlock_init/c\
  __libc_rwlock_define_initialized (, reset_lock);\
  memcpy (&lock, &reset_lock, sizeof (lock));' \
      -i stdlib/abort.c

  # 4) diretório de build separado (recomendado) 7
  mkdir -v build
}

pkg_build() {
  cd build

  # LFS: garantir que ldconfig/sln vão para /usr/sbin 8
  echo "rootsbindir=/usr/sbin" > configparms

  # Configuração conforme LFS 8.5.1 9
  ../configure --prefix=/usr                   \
               --disable-werror                \
               --disable-nscd                  \
               libc_cv_slibdir=/usr/lib        \
               --enable-stack-protector=strong \
               --enable-kernel=5.4

  # O livro manda desabilitar um sanity check desatualizado antes do make: 10
  sed '/test-installation/s@$(PERL)@echo not running@' -i ../Makefile

  # Compilar
  make

  # Testes: no livro são críticos ("não pule"). Aqui eu deixo escapinha
  # via ADM_SKIP_TESTS=1 se você quiser acelerar.
  if [[ "${ADM_SKIP_TESTS:-0}" != "1" ]]; then
    make check
  else
    echo "===> ADM_SKIP_TESTS=1 definido, pulando 'make check' de glibc."
  fi
}

pkg_install() {
  cd build

  # Instalar no DESTDIR para o adm empacotar depois 11
  make DESTDIR="${PKG_DESTDIR}" install

  # Ajustar ldd DENTRO do DESTDIR, não em /usr/bin direto 12
  if [[ -f "${PKG_DESTDIR}/usr/bin/ldd" ]]; then
    sed '/RTLDLIST=/s@/usr@@g' -i "${PKG_DESTDIR}/usr/bin/ldd"
  fi

  # NOTA IMPORTANTE:
  #  - /etc/nsswitch.conf
  #  - timezone (tzdata, /etc/localtime)
  #  - /etc/ld.so.conf
  #
  # O livro faz isso em 8.5.2 direto no sistema real (sem DESTDIR). 13
  # No teu adm eu recomendo deixar isso para a recipe 'glibc-config' e 'tzdata',
  # como já combinamos, pra não bagunçar /etc quando remover/atualizar glibc.
}

pkg_upstream_version() {
  # Pega a maior versão glibc-X.YZ no FTP oficial GNU 14
  local url="https://ftp.gnu.org/gnu/libc/"
  local latest=""

  if command -v curl >/dev/null 2>&1; then
    latest="$(
      curl -fsSL "$url" \
        | sed -n 's/.*glibc-\([0-9][0-9.]*\)\.tar\.xz.*/\1/p' \
        | sort -V \
        | tail -n1
    )"
  fi

  if [[ -n "$latest" ]]; then
    printf '%s\n' "$latest"
  else
    # fallback seguro: versão definida na própria recipe
    printf '%s\n' "$PKG_VERSION"
  fi
}
