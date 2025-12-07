# /opt/adm/packages/sys-devel/bison/bison.sh
#!/usr/bin/env bash

PKG_NAME="bison"
PKG_CATEGORY="sys-devel"
PKG_VERSION="3.8.2"
PKG_DESC="GNU Bison - gerador de analisadores sintáticos (parser generator)"
PKG_HOMEPAGE="https://www.gnu.org/software/bison/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "INSIRA_AQUI_O_SHA256_REAL_DO_BISON_3_8_2"
)

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
        "--docdir=/usr/share/doc/bison-$PKG_VERSION"
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

    # Instala em DESTDIR; o ADM depois aplica no ROOTFS
    make DESTDIR="$DESTDIR" install

    # Documentação extra (além do --docdir)
    install -d "$DESTDIR/usr/share/doc/bison-$PKG_VERSION"
    for f in README* NEWS* AUTHORS COPYING ChangeLog THANKS; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/bison-$PKG_VERSION/$f"
    done
}
