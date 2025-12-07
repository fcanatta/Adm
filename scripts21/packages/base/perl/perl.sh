# /opt/adm/packages/dev-lang/perl/perl.sh
#!/usr/bin/env bash

PKG_NAME="perl"
PKG_CATEGORY="base"
PKG_VERSION="5.42.0"
PKG_DESC="Perl 5 - linguagem de script prática para processamento de texto e automação"
PKG_HOMEPAGE="https://www.perl.org/"

PKG_SOURCE=(
    "https://www.cpan.org/src/5.0/perl-5.42.0.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "INSIRA_AQUI_O_SHA256_REAL_DO_PERL_5_42_0"
)

# Exemplo de dependências explícitas (ajuste conforme sua árvore do ADM):
# PKG_DEPENDS=(
#     "sys-libs/glibc"
#     "sys-devel/m4"
# )

pkg_build() {
    cd "$SRC_DIR"

    # Ex.: 5.42.0 -> 5.42 (usado nos diretórios de libs)
    local ver_short="${PKG_VERSION%.*}"

    # Usa toolchain/flags vindos dos profiles (glibc.profile/musl.profile):
    #   CC, CFLAGS, LDFLAGS etc.
    # -des = respostas padrão + não interativo
    sh Configure -des \
        -Dprefix=/usr \
        -Dvendorprefix=/usr \
        -Dprivlib="/usr/lib/perl5/${ver_short}/core_perl" \
        -Darchlib="/usr/lib/perl5/${ver_short}/core_perl" \
        -Dsitelib="/usr/lib/perl5/${ver_short}/site_perl" \
        -Dsitearch="/usr/lib/perl5/${ver_short}/site_perl" \
        -Dvendorlib="/usr/lib/perl5/${ver_short}/vendor_perl" \
        -Dvendorarch="/usr/lib/perl5/${ver_short}/vendor_perl" \
        -Dman1dir=/usr/share/man/man1 \
        -Dman3dir=/usr/share/man/man3 \
        -Dpager="/usr/bin/less -isR" \
        -Duseshrplib \
        -Dusethreads \
        -Dcc="${CC:-cc}" \
        -Doptimize="${CFLAGS:- -O2}" \
        -Dldflags="${LDFLAGS:-}"

    make
}

pkg_install() {
    cd "$SRC_DIR"

    # Honra DESTDIR para staging; o ADM depois copia para o ROOTFS
    make DESTDIR="$DESTDIR" install

    # Limpa metadados locais que não fazem sentido num gerenciador de pacotes
    find "$DESTDIR" \( -name perllocal.pod -o -name .packlist \) -type f -delete || true

    # Documentação básica
    install -d "$DESTDIR/usr/share/doc/perl-$PKG_VERSION"
    for f in README* Artistic Copying Changes*; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/perl-$PKG_VERSION/$f"
    done
}
