# /opt/adm/packages/sys-apps/sed/sed.sh
#!/usr/bin/env bash

PKG_NAME="sed"
PKG_CATEGORY="base"
PKG_VERSION="4.9"
PKG_DESC="GNU sed - editor de fluxo de texto"
PKG_HOMEPAGE="https://www.gnu.org/software/sed/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "6e226b732e1cd7390b6454f1253aa2d1f61002aadd8f5f31fb5d7bdb170950b3"
)

# PKG_DEPENDS=(
#     "sys-libs/glibc"
# )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
        "--bindir=/usr/bin"
        "--mandir=/usr/share/man"
        "--infodir=/usr/share/info"
    )

    # Integra com o profile (glibc/musl) via CHOST
    if [[ -n "${CHOST:-}" ]]; then
        conf_opts+=("--host=$CHOST")
        if [[ -x "./build-aux/config.guess" ]]; then
            conf_opts+=("--build=$(./build-aux/config.guess)")
        fi
    fi

    ./configure "${conf_opts[@]}"
    make
}

pkg_install() {
    cd "$SRC_DIR"

    # Instala em DESTDIR; o ADM depois aplica no ROOTFS
    make DESTDIR="$DESTDIR" install

    # Em layout /usr-merge, garantir /bin/sed -> /usr/bin/sed (opcional)
    install -d "$DESTDIR/bin"
    if [[ -x "$DESTDIR/usr/bin/sed" ]]; then
        ln -sf ../usr/bin/sed "$DESTDIR/bin/sed"
    fi

    # Documentação básica
    install -d "$DESTDIR/usr/share/doc/sed-$PKG_VERSION"
    for f in README NEWS AUTHORS COPYING ChangeLog THANKS; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/sed-$PKG_VERSION/$f"
    done
}
