# /opt/adm/packages/sys-apps/patch/patch.sh
#!/usr/bin/env bash

PKG_NAME="patch"
PKG_CATEGORY="sys-apps"
PKG_VERSION="2.8"
PKG_DESC="GNU Patch - aplica patches estilo diff em arquivos"
PKG_HOMEPAGE="https://www.gnu.org/software/patch/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/patch/patch-2.8.tar.xz"
)

# ATENÇÃO:
# Use o SHA-256 real do tarball patch-2.8.tar.xz calculado com sha256sum.
PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "INSIRA_AQUI_O_SHA256_REAL_DO_PATCH_2_8"
)

# Se quiser declarar dependências explícitas:
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
        elif [[ -x "./config.guess" ]]; then
            conf_opts+=("--build=$(./config.guess)")
        fi
    fi

    ./configure "${conf_opts[@]}"
    make
}

pkg_install() {
    cd "$SRC_DIR"

    # Instala tudo em DESTDIR; o ADM faz o merge no ROOTFS depois
    make DESTDIR="$DESTDIR" install

    # Documentação básica
    install -d "$DESTDIR/usr/share/doc/patch-$PKG_VERSION"
    for f in README NEWS AUTHORS COPYING ChangeLog THANKS; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/patch-$PKG_VERSION/$f"
    done
}
