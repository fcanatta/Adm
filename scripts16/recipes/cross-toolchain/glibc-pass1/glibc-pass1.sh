# Recipe para adm: Glibc-2.42 (cross-toolchain, capítulo 5.5)
# LFS r12.4-46 - 5.5. Glibc-2.42

PKG_NAME="glibc-pass1"
PKG_VERSION="2.42"
PKG_RELEASE="1"

PKG_DESC="Glibc 2.42 para o sysroot do cross-toolchain (capítulo 5.5 do LFS)"
PKG_URL="https://www.gnu.org/software/libc/"
PKG_LICENSE="LGPL-2.1-or-later"
PKG_GROUPS="cross-toolchain"

# Fontes: tarball + patch FHS (apenas ele é usado no capítulo 5)
PKG_SOURCES="
https://ftp.gnu.org/gnu/glibc/glibc-2.42.tar.xz
https://www.linuxfromscratch.org/patches/lfs/development/glibc-2.42-fhs-1.patch
"

# MD5 na mesma ordem dos sources
PKG_MD5S="
23c6f5a27932b435cae94e087cb8b1f5
9a5997c3452909b1769918c759eff8a2
"

# Sem SHA256 (pra não precisar preencher pra todos os sources)
PKG_SHA256S=""

# Ordem lógica: depende do gcc-pass1 e dos headers do kernel
PKG_DEPENDS="linux-headers gcc-pass1 binutils-pass1"

pkg_prepare() {
  # Estamos dentro de glibc-2.42

  # Patch FHS (var/db -> locations FHS)
  patch -Np1 -i ../glibc-2.42-fhs-1.patch

  # Diretório de build dedicado 
  mkdir -v build
}

pkg_build() {
  cd build

  # Raiz do toolchain (onde estão $TARGET-gcc, $TARGET-ld, etc.)
  local cross_root="${ADM_CROSS_ROOT:-/usr/src/cross-toolchain}"

  # Sysroot (equivalente ao $LFS do livro)
  local sysroot="${ADM_CROSS_SYSROOT:-${LFS:-/mnt/lfs}}"

  # Triplet alvo, equivalente a $LFS_TGT (ex: x86_64-lfs-linux-gnu)
  local tgt="${ADM_CROSS_TARGET:-${LFS_TGT:-}}"
  if [[ -z "$tgt" ]]; then
    die "Defina ADM_CROSS_TARGET ou LFS_TGT (ex: x86_64-lfs-linux-gnu) antes de construir glibc-pass1."
  fi

  # Garante que vamos usar o cross-binutils e o cross-gcc certos
  PATH="${cross_root}/bin:${PATH}"
  export PATH

  # Também exporta LFS para ficar fiel ao livro (usado só em mensagens)
  LFS="${sysroot}"
  export LFS

  # ldconfig e sln em /usr/sbin
  echo "rootsbindir=/usr/sbin" > configparms

  # Configure cross, usando o toolchain em $cross_root e sysroot em $sysroot
  ../configure                             \
        --prefix=/usr                      \
        --host="${tgt}"                    \
        --build="$(../scripts/config.guess)" \
        --disable-nscd                     \
        libc_cv_slibdir=/usr/lib           \
        --enable-kernel=5.4

  # Compilar
  make
  # O livro não roda 'make check' aqui, só sanity checks manuais depois.
}

pkg_install() {
  cd build

  local sysroot="${ADM_CROSS_SYSROOT:-${LFS:-/mnt/lfs}}"

  # Instalação no sysroot, como "make DESTDIR=$LFS install" do livro
  make DESTDIR="${PKG_DESTDIR}${sysroot}" install

  # Corrige o ldd dentro do sysroot, não no host 9
  if [[ -f "${PKG_DESTDIR}${sysroot}/usr/bin/ldd" ]]; then
    sed '/RTLDLIST=/s@/usr@@g' -i "${PKG_DESTDIR}${sysroot}/usr/bin/ldd"
  fi

  # Symlinks de LSB em $LFS/lib* (agora no sysroot empacotado) 
  case "$(uname -m)" in
    i?86)
      mkdir -pv "${PKG_DESTDIR}${sysroot}/lib"
      ln -sfv ld-linux.so.2 \
        "${PKG_DESTDIR}${sysroot}/lib/ld-lsb.so.3"
      ;;
    x86_64)
      mkdir -pv "${PKG_DESTDIR}${sysroot}/lib64"
      ln -sfv ../lib/ld-linux-x86-64.so.2 \
        "${PKG_DESTDIR}${sysroot}/lib64/ld-linux-x86-64.so.2"
      ln -sfv ../lib/ld-linux-x86-64.so.2 \
        "${PKG_DESTDIR}${sysroot}/lib64/ld-lsb-x86-64.so.3"
      ;;
  esac

  # NOTA: os sanity checks do livro (dummy.c, readelf, grep em dummy.log) 
  # são ótimos, mas interativos. Eu não rodo aqui dentro do recipe pra não
  # travar builds automáticos. Você pode rodá-los manualmente após o adm
  # instalar o pacote, exatamente como mostrado no capítulo 5.5.
}

pkg_upstream_version() {
  # Mesmo esquema do outro glibc: pega maior glibc-X.YZ em ftp.gnu.org
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
    printf '%s\n' "$PKG_VERSION"
  fi
}
