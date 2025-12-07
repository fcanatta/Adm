#!/usr/bin/env bash

# Metadados do pacote
PKG_NAME="m4"
PKG_CATEGORY="sys-devel"
PKG_VERSION="1.4.20"
PKG_DESC="GNU M4 - processador de macros tradicional do Unix"
PKG_HOMEPAGE="https://www.gnu.org/software/m4/"

# Fonte oficial (tar.xz) + checksum SHA-256
PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/m4/m4-1.4.20.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "e236ea3a1ccf5f6c270b1c4bb60726f371fa49459a8eaaebc90b216b328daf2b"
)

# Se você tiver um pacote de libc específico, pode declarar aqui.
# Como não sabemos o nome exato no teu tree, deixo sem dependências explícitas.
# PKG_DEPENDS=()

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
        "--disable-dependency-tracking"
    )

    # Usa CHOST se definido pelo profile (glibc.profile / musl.profile)
    if [[ -n "${CHOST:-}" ]]; then
        conf_opts+=("--host=$CHOST")
    fi

    # Garante um valor sensato de --build usando o script fornecido pelo próprio m4
    if [[ -x "./build-aux/config.guess" ]]; then
        conf_opts+=("--build=$(./build-aux/config.guess)")
    fi

    ./configure "${conf_opts[@]}"
    make
}

pkg_install() {
    cd "$SRC_DIR"

    # Instala dentro do DESTDIR, o ADM depois copia para o ROOTFS
    make DESTDIR="$DESTDIR" install

    # Documentação básica em /usr/share/doc/m4
    install -d "$DESTDIR/usr/share/doc/$PKG_NAME"
    for f in AUTHORS COPYING NEWS README THANKS; do
        if [[ -f "$f" ]]; then
            install -m 644 "$f" "$DESTDIR/usr/share/doc/$PKG_NAME/$f"
        fi
    done
}
