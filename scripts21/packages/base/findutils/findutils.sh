# /opt/adm/packages/sys-apps/findutils/findutils.sh
#!/usr/bin/env bash

PKG_NAME="findutils"
PKG_CATEGORY="base"
PKG_VERSION="4.10.0"
PKG_DESC="GNU Findutils - find, locate, updatedb e xargs"
PKG_HOMEPAGE="https://www.gnu.org/software/findutils/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/findutils/findutils-4.10.0.tar.xz"
)

PKG_CHECKSUM_TYPE="md5"
PKG_CHECKSUMS=(
    "870cfd71c07d37ebe56f9f4aaf4ad872"
)

# Exemplo (se quiser declarar dependências explícitas):
# PKG_DEPENDS=(
#     "sys-libs/glibc"
# )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
        "--localstatedir=/var/lib/locate"
    )

    # Integra com o profile do ADM (glibc/musl) via CHOST
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

    # Instala em DESTDIR, o ADM depois aplica no ROOTFS
    make DESTDIR="$DESTDIR" install

    # Documentação básica
    install -d "$DESTDIR/usr/share/doc/findutils-$PKG_VERSION"
    for f in NEWS README AUTHORS COPYING THANKS; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/findutils-$PKG_VERSION/$f"
    done
}
