# /opt/adm/packages/sys-apps/grep/grep.sh
#!/usr/bin/env bash

PKG_NAME="grep"
PKG_CATEGORY="base"
PKG_VERSION="3.12"
PKG_DESC="GNU Grep - ferramenta de busca de padrões em texto"
PKG_HOMEPAGE="https://www.gnu.org/software/grep/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/grep/grep-3.12.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "bd36100727c406d1247ce9409e1115c002b2a7e76910fd6f53cd8182c13358c3"
)

# Exemplo de dependências explícitas:
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

    # Integra com o profile glibc/musl via CHOST
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
    install -d "$DESTDIR/usr/share/doc/grep-$PKG_VERSION"
    for f in NEWS README AUTHORS COPYING ChangeLog THANKS; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/grep-$PKG_VERSION/$f"
    done
}
