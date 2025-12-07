#!/usr/bin/env bash

PKG_NAME="diffutils"
PKG_CATEGORY="base"
PKG_VERSION="3.12"
PKG_DESC="GNU Diffutils - ferramentas para comparar arquivos e diretórios"
PKG_HOMEPAGE="https://www.gnu.org/software/diffutils/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/diffutils/diffutils-3.12.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "7c8b7f9fc8609141fdea9cece85249d308624391ff61dedaf528fcb337727dfd"
)

# Ajuste se quiser forçar alguma dependência explícita
# PKG_DEPENDS=(
#     "sys-libs/glibc"
# )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
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

    # Instala tudo em DESTDIR, o ADM depois copia para o ROOTFS
    make DESTDIR="$DESTDIR" install

    # Documentação
    install -d "$DESTDIR/usr/share/doc/diffutils-$PKG_VERSION"
    for f in NEWS README AUTHORS COPYING THANKS; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/diffutils-$PKG_VERSION/$f"
    done
}
