# /opt/adm/packages/sys-apps/gawk/gawk.sh
#!/usr/bin/env bash

PKG_NAME="gawk"
PKG_CATEGORY="base"
PKG_VERSION="5.3.2"
PKG_DESC="GNU Awk - linguagem para processamento de texto e relatórios"
PKG_HOMEPAGE="https://www.gnu.org/software/gawk/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/gawk/gawk-5.3.2.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "f8c3486509de705192138b00ef2c00bbbdd0e84c30d5c07d23fc73a9dc4cc9cc"
)

# Exemplo de dependências, se quiser declarar explicitamente:
# PKG_DEPENDS=(
#     "sys-libs/glibc"
# )

pkg_build() {
    cd "$SRC_DIR"

    # Evita instalar coisas em "extras" (padrão LFS)
    sed -i 's/extras//' Makefile.in || true

    local conf_opts=(
        "--prefix=/usr"
        "--mandir=/usr/share/man"
        "--infodir=/usr/share/info"
        "--docdir=/usr/share/doc/gawk-$PKG_VERSION"
    )

    # Integra com o profile glibc/musl via CHOST
    if [[ -n "${CHOST:-}" ]]; then
        conf_opts+=("--host=$CHOST")
        if [[ -x "build-aux/config.guess" ]]; then
            conf_opts+=("--build=$(build-aux/config.guess)")
        fi
    fi

    ./configure "${conf_opts[@]}"
    make
}

pkg_install() {
    cd "$SRC_DIR"

    # Instala tudo em DESTDIR; o ADM depois copia para o ROOTFS
    make DESTDIR="$DESTDIR" install

    # Garante /usr/bin/awk apontando para gawk
    if [[ -x "$DESTDIR/usr/bin/gawk" ]]; then
        ln -sf gawk "$DESTDIR/usr/bin/awk"
    fi

    # Documentação extra básica (se ainda não tiver ido via docdir)
    install -d "$DESTDIR/usr/share/doc/gawk-$PKG_VERSION"
    for f in README NEWS AUTHORS COPYING ChangeLog; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/gawk-$PKG_VERSION/$f"
    done
}
