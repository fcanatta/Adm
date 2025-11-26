# musl-1.2.5 com patches CVE-2025-26519
# Patches oficiais:
#  - 0001: iconv: fix erroneous input validation in EUC-KR decoder
#  - 0002: iconv: harden UTF-8 output code path against input decoder bugs
#
# Advisory e patches:
#   https://www.openwall.com/lists/musl/2025/02/13/1
#   https://www.openwall.com/lists/musl/2025/02/13/1/1
#   https://www.openwall.com/lists/musl/2025/02/13/1/2

PKG_NAME="musl"
PKG_VERSION="1.2.5"
PKG_RELEASE="1"

# Você pediu explicitamente o grupo "musl"
PKG_GROUPS="musl"

PKG_DESC="musl libc ${PKG_VERSION} com patches de segurança CVE-2025-26519 aplicados"
PKG_URL="https://musl.libc.org/"
PKG_LICENSE="MIT"

# Fonte oficial + patches de segurança do Openwall.
PKG_SOURCES="\
https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz \
https://www.openwall.com/lists/musl/2025/02/13/1/1 \
https://www.openwall.com/lists/musl/2025/02/13/1/2"

# SHA256 apenas do tarball principal (os patches já são minúsculos e vêm direto do maintainer).
# hash verificado em múltiplas fontes. 1
PKG_SHA256S="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

# musl precisa de headers do kernel pra compilar
PKG_DEPENDS="linux-headers"

###############################################################################
# Build notes
#
# O próprio FAQ do musl recomenda basicamente:
#   ./configure --prefix=<path>
#   make
#   make install
# com cuidado para não usar prefix que colida com outra libc a menos que o
# sistema já seja baseado em musl. 2
###############################################################################

pkg_prepare() {
  # Diretório fonte, por ex.: musl-1.2.5/

  # 1) Aplicar os patches de segurança do advisory (ordem importa!)
  #
  # Os downloads das URLs 2 e 3 vão cair no ADM_SRC_CACHE com nomes "1" e "2"
  # (basename da URL). Se quiser, você pode renomeá-los aqui pra ficar mais
  # legível.
  cp -v "$ADM_SRC_CACHE/1" musl-CVE-2025-26519-0001.patch
  cp -v "$ADM_SRC_CACHE/2" musl-CVE-2025-26519-0002.patch

  # Patch 1: corrige validação de entrada na decodificação EUC-KR em iconv. 3
  patch -Np1 -i musl-CVE-2025-26519-0001.patch

  # Patch 2: endurece o caminho de saída UTF-8 contra bugs de decodificador. 4
  patch -Np1 -i musl-CVE-2025-26519-0002.patch

  # 2) Configurar o build
  #
  # IMPORTANTE: só use --prefix=/usr se esse sistema já for todo em musl.
  # Se estiver testando em sistema glibc, prefira algo como /usr/musl ou /opt/musl.
  #
  # O ADM vai fazer staging em $PKG_DESTDIR, então aqui o prefix é o destino
  # “real” no sistema final.
  : "${MUSL_PREFIX:=/usr}"

  ./configure \
    --prefix="${MUSL_PREFIX}"
}

pkg_build() {
  # Compila a libc
  make
}

pkg_check() {
  # musl não tem uma suíte de testes padrão "make check" documentada.
  # Se você criar testes próprios depois, pode encaixar aqui.
  :
}

pkg_install() {
  # Instala em staging via DESTDIR (o próprio adm define PKG_DESTDIR)
  make DESTDIR="$PKG_DESTDIR" install

  # Opcional: instalar docs em /usr/share/doc/musl-<versão>
  install -d "$PKG_DESTDIR/usr/share/doc/${PKG_NAME}-${PKG_VERSION}"
  install -m644 COPYRIGHT README "$PKG_DESTDIR/usr/share/doc/${PKG_NAME}-${PKG_VERSION}/" 2>/dev/null || true
}

# Para upgrades:
# usa o helper genérico do adm pra olhar releases em https://musl.libc.org/releases
# e pegar a MAIOR versão (por ex., 1.2.6 quando sair). 5
pkg_upstream_version() {
  adm_generic_upstream_version
}
