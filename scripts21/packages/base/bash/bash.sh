#!/usr/bin/env bash

PKG_NAME="bash"
PKG_CATEGORY="app-shells"
PKG_VERSION="5.3"
PKG_DESC="GNU Bash - Bourne Again SHell"
PKG_HOMEPAGE="https://www.gnu.org/software/bash/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba"
)

# Se você mantiver ncurses / readline separados, pode ativar algo assim:
# PKG_DEPENDS=(
#     "sys-libs/ncurses"
#     "sys-libs/readline"
# )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
        "--mandir=/usr/share/man"
        "--infodir=/usr/share/info"
        "--docdir=/usr/share/doc/bash-$PKG_VERSION"
        "--without-bash-malloc"
    )

    # Se o profile definir CHOST, respeita
    if [[ -n "${CHOST:-}" ]]; then
        conf_opts+=("--host=$CHOST")
        if [[ -x "./support/config.guess" ]]; then
            conf_opts+=("--build=$(./support/config.guess)")
        fi
    fi

    ./configure "${conf_opts[@]}"
    make
}

pkg_install() {
    cd "$SRC_DIR"

    # Instala sob DESTDIR, o ADM faz o merge pro ROOTFS depois
    make DESTDIR="$DESTDIR" install

    # Garante /bin/bash como symlink para /usr/bin/bash (layout usr-merge friendly)
    install -d "$DESTDIR/bin"
    if [[ -x "$DESTDIR/usr/bin/bash" ]]; then
        ln -sf ../usr/bin/bash "$DESTDIR/bin/bash"
    fi

    # Pequena doc extra, caso queira algo a mais
    if [[ -f "README" || -f "COPYING" ]]; then
        install -d "$DESTDIR/usr/share/doc/bash-$PKG_VERSION"
        for f in README NEWS COPYING AUTHORS CHANGES; do
            [[ -f "$f" ]] || continue
            install -m 644 "$f" "$DESTDIR/usr/share/doc/bash-$PKG_VERSION/$f"
        done
    fi
}
