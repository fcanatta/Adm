#!/usr/bin/env bash

PKG_NAME="ncurses"
PKG_CATEGORY="base"
PKG_VERSION="6.5-20250809"
PKG_DESC="Ncurses - bibliotecas para manipulação independente de terminal de telas de caracteres"
PKG_HOMEPAGE="https://www.gnu.org/software/ncurses/"

PKG_SOURCE=(
    "https://invisible-mirror.net/archives/ncurses/current/ncurses-6.5-20250809.tgz"
)

PKG_CHECKSUM_TYPE="md5"
PKG_CHECKSUMS=(
    "679987405412f970561cc85e1e6428a2"
)

# Se quiser, você pode adicionar dependências explícitas aqui, por ex:
# PKG_DEPENDS=( "sys-devel/m4" )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
        "--mandir=/usr/share/man"
        "--with-shared"
        "--without-debug"
        "--without-normal"
        "--with-cxx-shared"
        "--enable-pc-files"
        "--with-pkg-config-libdir=/usr/lib/pkgconfig"
    )

    # Integra com o profile do ADM (glibc/musl) se CHOST estiver definido
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

    # Instala tudo dentro do DESTDIR, o ADM depois copia para o ROOTFS
    make DESTDIR="$DESTDIR" install

    # Ajuste do curses.h para forçar ABI wide-char (equivalente ao LFS)
    if [[ -f "$DESTDIR/usr/include/curses.h" ]]; then
        sed -e 's/^#if.*XOPEN.*$/#if 1/' \
            -i "$DESTDIR/usr/include/curses.h"
    fi

    # Symlinks para enganar programas que procuram versões não-wide
    if [[ -d "$DESTDIR/usr/lib" ]]; then
        for lib in ncurses form panel menu ; do
            if [[ -e "$DESTDIR/usr/lib/lib${lib}w.so" ]]; then
                ln -sf "lib${lib}w.so" "$DESTDIR/usr/lib/lib${lib}.so"
            fi
        done
    fi

    # Symlinks de .pc para as variantes wide
    if [[ -d "$DESTDIR/usr/lib/pkgconfig" ]]; then
        for lib in ncurses form panel menu ; do
            if [[ -e "$DESTDIR/usr/lib/pkgconfig/${lib}w.pc" ]]; then
                ln -sf "${lib}w.pc" "$DESTDIR/usr/lib/pkgconfig/${lib}.pc"
            fi
        done
    fi

    # Compatibilidade com -lcurses
    if [[ -e "$DESTDIR/usr/lib/libncursesw.so" ]]; then
        ln -sf "libncursesw.so" "$DESTDIR/usr/lib/libcurses.so"
    fi

    # Documentação
    if [[ -d "doc" ]]; then
        install -d "$DESTDIR/usr/share/doc/ncurses-$PKG_VERSION"
        cp -av doc/* "$DESTDIR/usr/share/doc/ncurses-$PKG_VERSION"/
    fi
}
