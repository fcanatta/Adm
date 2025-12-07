# /opt/adm/packages/app-arch/gzip/gzip.sh
#!/usr/bin/env bash

PKG_NAME="gzip"
PKG_CATEGORY="base"
PKG_VERSION="1.14"
PKG_DESC="GNU Gzip - compactador de arquivos"
PKG_HOMEPAGE="https://www.gnu.org/software/gzip/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/gzip/gzip-1.14.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "03a9964a27c4b69c4401d80e1cccaebc0501ddf781e4b57c2502a4be0aff2518"
)

# Exemplo, caso queira forçar dependências explícitas:
# PKG_DEPENDS=(
#     "sys-libs/glibc"
# )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
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

    # Instala no DESTDIR; o ADM depois aplica no ROOTFS
    make DESTDIR="$DESTDIR" install

    # Em layout /usr-merge, garantir /bin/gzip -> /usr/bin/gzip (opcional, mas útil)
    install -d "$DESTDIR/bin"
    if [[ -x "$DESTDIR/usr/bin/gzip" ]]; then
        ln -sf ../usr/bin/gzip "$DESTDIR/bin/gzip"
    fi

    # Documentação básica extra (se ainda não tiver ido)
    install -d "$DESTDIR/usr/share/doc/gzip-$PKG_VERSION"
    for f in README NEWS AUTHORS COPYING ChangeLog; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/gzip-$PKG_VERSION/$f"
    done
}
