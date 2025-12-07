# /opt/adm/packages/sys-apps/texinfo/texinfo.sh
#!/usr/bin/env bash

PKG_NAME="texinfo"
PKG_CATEGORY="base"
PKG_VERSION="7.2"
PKG_DESC="GNU Texinfo - sistema de documentação usado pelo projeto GNU (formatos Info, HTML, etc.)"
PKG_HOMEPAGE="https://www.gnu.org/software/texinfo/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/texinfo/texinfo-7.2.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "INSIRA_AQUI_O_SHA256_REAL_DO_TEXINFO_7_2"
)

# Exemplo de dependências explícitas, ajuste se quiser:
# PKG_DEPENDS=(
#     "sys-libs/ncurses"
#     "sys-libs/readline"
# )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
        "--libdir=/usr/lib"
        "--mandir=/usr/share/man"
        "--infodir=/usr/share/info"
        "--disable-static"
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

    # Instala tudo em DESTDIR; o ADM depois aplica no ROOTFS
    make DESTDIR="$DESTDIR" install

    # Documentação extra
    install -d "$DESTDIR/usr/share/doc/texinfo-$PKG_VERSION"
    for f in README* NEWS* AUTHORS COPYING ChangeLog THANKS; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/texinfo-$PKG_VERSION/$f"
    done
}
