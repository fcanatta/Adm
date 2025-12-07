# /opt/adm/packages/sys-devel/make/make.sh
#!/usr/bin/env bash

PKG_NAME="make"
PKG_CATEGORY="base"
PKG_VERSION="4.4.1"
PKG_DESC="GNU Make - utilitário de automação de compilação"
PKG_HOMEPAGE="https://www.gnu.org/software/make/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "dd15fa11ab55a41770119fb0f8a3e004a72d5c3239aa583bed2e874f5c101a68"
)

# Exemplo se quiser dependências explícitas:
# PKG_DEPENDS=(
#     "sys-libs/glibc"
# )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
        "--program-prefix="         # sem prefixo tipo 'gmake'
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

    # Garante /usr/bin/make e, opcionalmente, /bin/make como link
    install -d "$DESTDIR/bin"
    if [[ -x "$DESTDIR/usr/bin/make" ]]; then
        ln -sf ../usr/bin/make "$DESTDIR/bin/make"
    fi

    # Documentação extra
    install -d "$DESTDIR/usr/share/doc/make-$PKG_VERSION"
    for f in README NEWS AUTHORS COPYING ChangeLog; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/make-$PKG_VERSION/$f"
    done
}
