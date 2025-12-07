# /opt/adm/packages/app-arch/xz/xz.sh
#!/usr/bin/env bash

PKG_NAME="xz"
PKG_CATEGORY="app-arch"
PKG_VERSION="5.8.1"
PKG_DESC="XZ Utils - compactação LZMA/LZMA2 (xz, unxz, liblzma)"
PKG_HOMEPAGE="https://tukaani.org/xz/"

PKG_SOURCE=(
    "https://tukaani.org/xz/xz-5.8.1.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "3d28ffb8dc091f46f9f6d5f330c182b9af2dcd9daa9cb3493ece7ec5319241f5"
)

# Exemplo, se quiser dependências explícitas:
# PKG_DEPENDS=(
#     "sys-libs/glibc"
# )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
        "--libdir=/usr/lib"
        "--bindir=/usr/bin"
        "--mandir=/usr/share/man"
        "--infodir=/usr/share/info"
        "--disable-static"
    )

    # Integra com o profile (glibc/musl) via CHOST
    if [[ -n "${CHOST:-}" ]]; then
        conf_opts+=("--host=$CHOST")
        if [[ -x "./config.guess" ]]; then
            conf_opts+=("--build=$(./config.guess)")
        fi
    fi

    ./configure "${conf_opts[@]}"
    make
}

pkg_install() {
    cd "$SRC_DIR"

    # Instala no DESTDIR; o ADM depois aplica no ROOTFS
    make DESTDIR="$DESTDIR" install

    # Em layout /usr-merge, garantir /bin/xz -> /usr/bin/xz (opcional, mas útil)
    install -d "$DESTDIR/bin"
    if [[ -x "$DESTDIR/usr/bin/xz" ]]; then
        ln -sf ../usr/bin/xz "$DESTDIR/bin/xz"
    fi

    # Documentação básica extra
    install -d "$DESTDIR/usr/share/doc/xz-$PKG_VERSION"
    for f in README NEWS AUTHORS COPYING ChangeLog THANKS; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/xz-$PKG_VERSION/$f"
    done
}
