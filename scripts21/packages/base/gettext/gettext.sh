# /opt/adm/packages/sys-devel/gettext/gettext.sh
#!/usr/bin/env bash

PKG_NAME="gettext"
PKG_CATEGORY="base"
PKG_VERSION="0.26"
PKG_DESC="GNU Gettext - ferramentas e bibliotecas para internacionalização (i18n)"
PKG_HOMEPAGE="https://www.gnu.org/software/gettext/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/gettext/gettext-0.26.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "d1fb86e260cfe7da6031f94d2e44c0da55903dbae0a2fa0fae78c91ae1b56f00"
)

# Exemplo de dependências, se quiser declarar explicitamente:
# PKG_DEPENDS=(
#     "sys-libs/glibc"
# )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
        "--libdir=/usr/lib"
        "--mandir=/usr/share/man"
        "--infodir=/usr/share/info"
        "--disable-static"
        "--docdir=/usr/share/doc/gettext-$PKG_VERSION"
    )

    # Integra com o profile (glibc/musl) via CHOST
    if [[ -n "${CHOST:-}" ]]; then
        conf_opts+=("--host=$CHOST")
        if [[ -x "./build-aux/config.guess" ]]; then
            conf_opts+=("--build=$(./build-aux/config.guess)")
        elif [[ -x "./config.guess" ]]; then
            conf_opts+=("--build=$(./config.guess)")
        fi
    fi

    ./configure "${conf_opts[@]}"
    make
}

pkg_install() {
    cd "$SRC_DIR"

    # Instala tudo em DESTDIR; o ADM depois faz o merge no ROOTFS
    make DESTDIR="$DESTDIR" install

    # Em alguns setups, libintl preloadable precisa de permissão 0755
    if [[ -f "$DESTDIR/usr/lib/preloadable_libintl.so" ]]; then
        chmod 0755 "$DESTDIR/usr/lib/preloadable_libintl.so"
    fi

    # Documentação extra (se ainda não tiver ido via --docdir)
    install -d "$DESTDIR/usr/share/doc/gettext-$PKG_VERSION"
    for f in README* NEWS* AUTHORS COPYING ChangeLog THANKS; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/gettext-$PKG_VERSION/$f"
    done
}
