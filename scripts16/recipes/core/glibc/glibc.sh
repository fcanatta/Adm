# glibc-${PKG_VERSION} - GNU C Library (LFS 12.4 r12.4.46)

PKG_NAME="glibc"
PKG_VERSION="2.42"
PKG_RELEASE="1"

# Ajuste grupos conforme sua organização
PKG_GROUPS="core toolchain"

PKG_DESC="GNU C Library (glibc) ${PKG_VERSION} conforme LFS 12.4, capítulo 8.5"
PKG_URL="https://www.gnu.org/software/libc/"
PKG_LICENSE="GPL-2.0-or-later AND LGPL-2.1-or-later"

# Fontes:
#  - glibc-${PKG_VERSION}
#  - patch FHS do LFS
#  - tzdata2025b (para zona horária, usado em 8.5.2.2)
PKG_SOURCES="\
https://ftp.gnu.org/gnu/libc/glibc-${PKG_VERSION}.tar.xz \
https://ftp.lfs-matrix.net/pub/lfs/lfs-packages/12.4/glibc-${PKG_VERSION}-fhs-1.patch \
https://ftp.lfs-matrix.net/pub/lfs/lfs-packages/12.4/tzdata2025b.tar.gz"

# MD5s oficiais do bundle LFS 12.4
# (md5sums em ftp.lfs-matrix.net/pub/lfs/lfs-packages/12.4/md5sums)
PKG_MD5S="\
23c6f5a27932b435cae94e087cb8b1f5 \
9a5997c3452909b1769918c759eff8a2 \
acd4360d8a5c3ef320b9db88d275dae6"

# Dependências mínimas (ajuste os nomes conforme seus outros recipes)
# - linux-api-headers (ou similar)
PKG_DEPENDS="linux-headers"

###############################################################################
# Etapas de build (LFS 12.4, seção 8.5)
###############################################################################

pkg_prepare() {
  # Estamos em $srcdir = glibc-${PKG_VERSION}

  # 1. Patch FHS: faz programas da glibc usarem diretórios compatíveis com FHS
  #    Em LFS: patch -Np1 -i ../glibc-${PKG_VERSION}-fhs-1.patch
  patch -Np1 -i "$ADM_SRC_CACHE/glibc-${PKG_VERSION}-fhs-1.patch"

  # 2. Fix para abort.c (compat com Valgrind em BLFS)
  #    Em LFS:
  #    sed -e '/unistd.h/i #include <string.h>' \
  #        -e '/libc_rwlock_init/c\ ...' -i stdlib/abort.c
  sed -e '/unistd.h/i #include <string.h>' \
      -e '/libc_rwlock_init/c\
  __libc_rwlock_define_initialized (, reset_lock);\
  memcpy (&lock, &reset_lock, sizeof (lock));' \
      -i stdlib/abort.c

  # 3. Diretório de build separado (recomendação da própria glibc/LFS)
  mkdir -v build
  cd build

  # 4. rootsbindir para ldconfig e sln em /usr/sbin (LFS 8.5.1)
  echo "rootsbindir=/usr/sbin" > configparms

  # 5. Configure principal (LFS 8.5.1)
  ../configure \
    --prefix=/usr                   \
    --disable-werror                \
    --disable-nscd                  \
    libc_cv_slibdir=/usr/lib        \
    --enable-stack-protector=strong \
    --enable-kernel=5.4
}

pkg_build() {
  # Já estamos dentro de build/ graças ao pkg_prepare()
  # LFS: make
  make
}

pkg_check() {
  # LFS: make check (considerado crítico)
  # Se o seu hardware for muito lento ou der timeout em alguns testes,
  # você pode exportar TIMEOUTFACTOR aqui antes do make check.
  make check
}

pkg_install() {
  # Ainda em build/

  # Em LFS, antes de "make install" eles:
  #  - evitam warning de /etc/ld.so.conf ausente
  #  - desativam a regra de test-installation
  #
  # Como usamos DESTDIR, não vamos tocar /etc real,
  # mas ainda queremos pular o test-installation.
  sed '/test-installation/s@$(PERL)@echo not running@' -i ../Makefile

  # 1. Instalação principal da glibc em DESTDIR (ajustado pelo adm)
  #
  # LFS: make install
  # Aqui: make DESTDIR="$PKG_DESTDIR" install
  make DESTDIR="$PKG_DESTDIR" install

  # 2. Corrigir ldd para não ter caminho hardcoded do loader (LFS 8.5.1)
  #    LFS: sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd
  sed '/RTLDLIST=/s@/usr@@g' -i "$PKG_DESTDIR/usr/bin/ldd"

  ###########################################################################
  # Locales (LFS 8.5.1 – instalação de localidades)
  #
  # LFS roda localedef direto no sistema; aqui usamos --prefix="$PKG_DESTDIR"
  # para jogar tudo dentro do pacote (em $PKG_DESTDIR/usr/lib/locale).
  ###########################################################################

  _ld_prefix="--prefix=$PKG_DESTDIR"

  localedef $_ld_prefix -i C      -f UTF-8      C.UTF-8
  localedef $_ld_prefix -i cs_CZ  -f UTF-8      cs_CZ.UTF-8
  localedef $_ld_prefix -i pt_BR  -f UTF-8      pt_BR.UTF-8 
  localedef $_ld_prefix -i de_DE  -f ISO-8859-1 de_DE
  localedef $_ld_prefix -i de_DE@euro -f ISO-8859-15 de_DE@euro
  localedef $_ld_prefix -i de_DE  -f UTF-8      de_DE.UTF-8
  localedef $_ld_prefix -i el_GR  -f ISO-8859-7 el_GR
  localedef $_ld_prefix -i en_GB  -f ISO-8859-1 en_GB
  localedef $_ld_prefix -i en_GB  -f UTF-8      en_GB.UTF-8
  localedef $_ld_prefix -i en_HK  -f ISO-8859-1 en_HK
  localedef $_ld_prefix -i en_PH  -f ISO-8859-1 en_PH
  localedef $_ld_prefix -i en_US  -f ISO-8859-1 en_US
  localedef $_ld_prefix -i en_US  -f UTF-8      en_US.UTF-8
  localedef $_ld_prefix -i es_ES  -f ISO-8859-15 es_ES@euro
  localedef $_ld_prefix -i es_MX  -f ISO-8859-1 es_MX
  localedef $_ld_prefix -i fa_IR  -f UTF-8      fa_IR
  localedef $_ld_prefix -i fr_FR  -f ISO-8859-1 fr_FR
  localedef $_ld_prefix -i fr_FR@euro -f ISO-8859-15 fr_FR@euro
  localedef $_ld_prefix -i fr_FR  -f UTF-8      fr_FR.UTF-8
  localedef $_ld_prefix -i is_IS  -f ISO-8859-1 is_IS
  localedef $_ld_prefix -i is_IS  -f UTF-8      is_IS.UTF-8
  localedef $_ld_prefix -i it_IT  -f ISO-8859-1 it_IT
  localedef $_ld_prefix -i it_IT  -f ISO-8859-15 it_IT@euro
  localedef $_ld_prefix -i it_IT  -f UTF-8      it_IT.UTF-8
  localedef $_ld_prefix -i ja_JP  -f EUC-JP    ja_JP
  localedef $_ld_prefix -i ja_JP  -f UTF-8     ja_JP.UTF-8
  localedef $_ld_prefix -i nl_NL@euro -f ISO-8859-15 nl_NL@euro
  localedef $_ld_prefix -i ru_RU  -f KOI8-R    ru_RU.KOI8-R
  localedef $_ld_prefix -i ru_RU  -f UTF-8     ru_RU.UTF-8
  localedef $_ld_prefix -i se_NO  -f UTF-8     se_NO.UTF-8
  localedef $_ld_prefix -i ta_IN  -f UTF-8     ta_IN.UTF-8
  localedef $_ld_prefix -i tr_TR  -f UTF-8     tr_TR.UTF-8
  localedef $_ld_prefix -i zh_CN  -f GB18030  zh_CN.GB18030
  localedef $_ld_prefix -i zh_HK  -f BIG5-HKSCS zh_HK.BIG5-HKSCS
  localedef $_ld_prefix -i zh_TW  -f UTF-8     zh_TW.UTF-8

  # Se quiser TODAS as localidades (como LFS sugere com make localedata/install-locales),
  # você poderia usar algo como (cuidado: é bem pesado):
  #
  #   make -C ../localedata install-locales DESTDIR="$PKG_DESTDIR"
  #
  # mas a abordagem acima com --prefix é mais controlada.

  ###########################################################################
  # Time zone data (LFS 8.5.2.2 – tzdata2025b)
  #
  # LFS:
  #   tar -xf ../../tzdata2025b.tar.gz
  #   ZONEINFO=/usr/share/zoneinfo
  #   ... zic ...
  #
  # Aqui usamos o tarball que já está em $ADM_SRC_CACHE e jogamos
  # os arquivos em $PKG_DESTDIR/usr/share/zoneinfo.
  ###########################################################################

  # Sai de build/ para não sujar demais o diretório de build
  cd ..

  tar -xf "$ADM_SRC_CACHE/tzdata2025b.tar.gz"

  ZONEINFO="$PKG_DESTDIR/usr/share/zoneinfo"
  mkdir -pv "$ZONEINFO"/{posix,right}

  pushd tzdata2025b* >/dev/null

  for tz in \
    etcetera southamerica northamerica europe africa antarctica \
    asia australasia backward
  do
    zic -L /dev/null   -d "$ZONEINFO"       "$tz"
    zic -L /dev/null   -d "$ZONEINFO/posix" "$tz"
    zic -L leapseconds -d "$ZONEINFO/right" "$tz"
  done

  cp -v zone.tab zone1970.tab iso3166.tab "$ZONEINFO"
  zic -d "$ZONEINFO" -p America/New_York

  popd >/dev/null
  unset ZONEINFO tz

  ###########################################################################
  # Arquivos de configuração básicos (LFS 8.5.2.1 e 8.5.2.3)
  #
  # - /etc/nsswitch.conf
  # - /etc/ld.so.conf (+ diretório include)
  #
  # Para não sobrescrever configs existentes no sistema final,
  # só criamos se ainda não existirem NO DESTDIR.
  ###########################################################################

  # nsswitch.conf (LFS 8.5.2.1)
  if [[ ! -f "$PKG_DESTDIR/etc/nsswitch.conf" ]]; then
    install -Dm644 /dev/stdin "$PKG_DESTDIR/etc/nsswitch.conf" << "EOF"
# Begin /etc/nsswitch.conf

passwd: files
group:  files
shadow: files

hosts:   files dns
networks: files

protocols: files
services:  files
ethers:    files
rpc:       files

# End /etc/nsswitch.conf
EOF
  fi

  # ld.so.conf (LFS 8.5.2.3)
  if [[ ! -f "$PKG_DESTDIR/etc/ld.so.conf" ]]; then
    install -Dm644 /dev/stdin "$PKG_DESTDIR/etc/ld.so.conf" << "EOF"
# Begin /etc/ld.so.conf
/usr/local/lib
/opt/lib

# Add an include directory
include /etc/ld.so.conf.d/*.conf

EOF
  fi

  mkdir -pv "$PKG_DESTDIR/etc/ld.so.conf.d"

  # Nota: o link /etc/localtime é específico do usuário/sistema, então
  # não criamos aqui. Depois de instalar o pacote, você faz:
  #   ln -sf /usr/share/zoneinfo/<Regiao/Cidade> /etc/localtime
}

# Opcional: se quiser integrar com mecanismo de checagem de versão upstream
# pkg_upstream_version() {
  # Simplesmente imprime a versão LFS-alinhada
  # echo "${PKG_VERSION}"
# }
# Integra com o mecanismo genérico do adm para descobrir a maior versão
# disponível no diretório de fontes (ftp.gnu.org/gnu/libc/).
#
# O adm_generic_upstream_version:
#   - usa o primeiro URL de PKG_SOURCES (glibc-${PKG_VERSION}.tar.xz),
#   - descobre o diretório (https://ftp.gnu.org/gnu/libc/),
#   - procura arquivos no formato glibc-<versão>.tar.xz
#   - e imprime a MAIOR versão encontrada.
#
# Depois, o core do adm (upstream_version_for) ainda compara isso com
# PKG_VERSION e escolhe o maior entre os dois.
pkg_upstream_version() {
  adm_generic_upstream_version
}
