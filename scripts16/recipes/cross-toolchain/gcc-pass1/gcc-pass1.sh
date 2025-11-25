# Recipe para adm: GCC-15.2.0 - Pass 1
# Linux From Scratch - Version r12.4-46, seção 5.3 (GCC-15.2.0 - Pass 1)

PKG_NAME="gcc-pass1"
PKG_VERSION="15.2.0"
PKG_RELEASE="1"

PKG_DESC="GCC (Passo 1 do cross-toolchain temporário)"
PKG_URL="https://gcc.gnu.org/"
PKG_LICENSE="GPL-3.0-or-later"
PKG_GROUPS="cross-toolchain cross-toolchain-musl"

# Fontes conforme capítulo 3.2 (All Packages) do LFS r12.4-46
#  - GCC 15.2.0
#  - MPFR 4.2.2
#  - GMP 6.3.0
#  - MPC 1.3.1
PKG_SOURCES="
https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz
https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz
https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz
https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz
"

# MD5 na mesma ordem de PKG_SOURCES (do capítulo 3.2)
PKG_MD5S="
b861b092bf1af683c46a8aa2e689a6fd
7c32c39b8b6e3ae85f25156228156061
956dc04e864001a9c22429f761f2c283
5c9bc658c9fd0f940e8e3e0f09530c62
"

# SHA256: para manter compatível com o adm (mesmo número ou vazio), deixo vazio
# -> só checa MD5, que é o que o LFS fornece para esses quatro.
PKG_SHA256S=""

# Ordem: precisa de binutils-pass1 já instalado (como no livro, Binutils Pass 1 vem antes)
PKG_DEPENDS="binutils-pass1"

pkg_prepare() {
  # Estamos dentro de gcc-15.2.0
  local src_cache="${ADM_SRC_CACHE:-/var/cache/adm/src}"

  # 1) Embutir MPFR, GMP e MPC dentro da árvore do GCC, como manda o livro
  tar -xf "${src_cache}/mpfr-4.2.2.tar.xz"
  mv -v mpfr-4.2.2 mpfr

  tar -xf "${src_cache}/gmp-6.3.0.tar.xz"
  mv -v gmp-6.3.0 gmp

  tar -xf "${src_cache}/mpc-1.3.1.tar.gz"
  mv -v mpc-1.3.1 mpc

  # 2) Em hosts x86_64, usar "lib" em vez de "lib64" para libs 64-bit
  case "$(uname -m)" in
    x86_64)
      sed -e '/m64=/s/lib64/lib/' \
          -i.orig gcc/config/i386/t-linux64
      ;;
  esac

  # 3) Diretório de build separado (recomendado pela doc do GCC)
  mkdir -v build
}

pkg_build() {
  cd build

  # Raiz do cross-toolchain (onde TUDO do cross vai morar)
  local cross_root="${ADM_CROSS_ROOT:-/usr/src/cross-toolchain}"

  # Sysroot do cross:
  #  - se ADM_CROSS_SYSROOT estiver setado, usa ele (ex: /mnt/lfs)
  #  - senão, se LFS estiver setado, usa o $LFS
  #  - fallback: usa o próprio cross_root
  local cross_sysroot="${ADM_CROSS_SYSROOT:-${LFS:-$cross_root}}"

  # ADICIONE ESTE BLOCO:
  # garante que o configure/make do GCC enxergam o binutils-pass1
  PATH="${cross_root}/bin:${PATH}"
  export PATH

  # Target triplet (igual ao LFS_TGT do livro, ex: x86_64-lfs-linux-gnu)
  local tgt="${ADM_CROSS_TARGET:-${LFS_TGT:-}}"
  if [[ -z "$tgt" ]]; then
    die "Defina ADM_CROSS_TARGET ou LFS_TGT (ex: x86_64-lfs-linux-gnu) antes de construir gcc-pass1."
  fi

  ../configure                  \
      --target="${tgt}"         \
      --prefix="${cross_root}"  \
      --with-glibc-version=2.42 \
      --with-sysroot="${cross_sysroot}" \
      --with-newlib             \
      --without-headers         \
      --enable-default-pie      \
      --enable-default-ssp      \
      --disable-nls             \
      --disable-shared          \
      --disable-multilib        \
      --disable-threads         \
      --disable-libatomic       \
      --disable-libgomp         \
      --disable-libquadmath     \
      --disable-libssp         \
      --disable-libvtv          \
      --disable-libstdcxx       \
      --enable-languages=c,c++

  # Compilar
  make
}

pkg_install() {
  cd build

  # Mesma raiz usada no configure
  local cross_root="${ADM_CROSS_ROOT:-/usr/src/cross-toolchain}"
  local cross_sysroot="${ADM_CROSS_SYSROOT:-${LFS:-$cross_root}}"
  local tgt="${ADM_CROSS_TARGET:-${LFS_TGT:-}}"
  if [[ -z "$tgt" ]]; then
    die "ADM_CROSS_TARGET/LFS_TGT não definido em pkg_install (gcc-pass1)."
  fi

  # IMPORTANTE:
  # Para o cross-toolchain funcionar de verdade, precisamos que os binários
  # estejam em /usr/src/cross-toolchain na árvore real (não só em DESTDIR).
  #
  # Então:
  #   1) make install direto no sistema (cross_root)
  #   2) gerar o limits.h interno completo (como no livro)
  #   3) copiar essa árvore real para o PKG_DESTDIR, para o adm empacotar.
  #
  # Isso deixa o cross toolchain utilizável imediatamente E ainda gera pacote.

  # 1) Instala diretamente em /usr/src/cross-toolchain
  make install

  # 2) Gerar o limits.h completo, exatamente como no LFS (só que usando o
  #    $tgt-gcc que acabamos de instalar em cross_root/bin).
  cd ..
  PATH="${cross_root}/bin:${PATH}"

  local libgcc_dir
  libgcc_dir="$(
    dirname "$("${tgt}"-gcc -print-libgcc-file-name)"
  )"

  mkdir -p "${libgcc_dir}/include"
  cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
      "${libgcc_dir}/include/limits.h"

  # 3) Copiar o cross-root real para dentro do DESTDIR, para o adm empacotar.
  #    Assim o pacote binário também contém o cross toolchain completo.
  if [[ -n "${PKG_DESTDIR:-}" ]]; then
    mkdir -p "${PKG_DESTDIR}/usr/src"
    # cp -a para preservar symlinks, perms, etc.
    cp -a "${cross_root}" "${PKG_DESTDIR}/usr/src/"
  fi
}

pkg_upstream_version() {
  # Descobre a versão mais recente de GCC no ftp oficial (para upgrade)
  local url="https://ftp.gnu.org/gnu/gcc/"
  local latest=""

  if command -v curl >/dev/null 2>&1; then
    latest="$(
      curl -fsSL "$url" \
        | sed -n 's/.*gcc-\([0-9][0-9.]*\)\/.*/\1/p' \
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
