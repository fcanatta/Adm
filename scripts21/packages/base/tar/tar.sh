# /opt/adm/packages/app-arch/tar/tar.sh
#!/usr/bin/env bash

PKG_NAME="tar"
PKG_CATEGORY="base"
PKG_VERSION="1.35"
PKG_DESC="GNU tar - utilitário de arquivamento de arquivos"
PKG_HOMEPAGE="https://www.gnu.org/software/tar/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "14d9846d163ab1ec7f0f5896a820d27f6f9735a782e8f8e30662545b90060454"
)

# Exemplo se quiser dependências explícitas:
# PKG_DEPENDS=(
#     "sys-libs/glibc"
# )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
        "--bindir=/usr/bin"
        "--sbindir=/usr/sbin"
        "--libdir=/usr/lib"
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

    # Em layout /usr-merge, garantir /bin/tar -> /usr/bin/tar (útil para scripts antigos)
    install -d "$DESTDIR/bin"
    if [[ -x "$DESTDIR/usr/bin/tar" ]]; then
        ln -sf ../usr/bin/tar "$DESTDIR/bin/tar"
    fi

    # Documentação básica extra
    install -d "$DESTDIR/usr/share/doc/tar-$PKG_VERSION"
    for f in README NEWS AUTHORS COPYING ChangeLog THANKS; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/tar-$PKG_VERSION/$f"
    done
}
