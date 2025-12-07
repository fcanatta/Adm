#!/usr/bin/env bash

PKG_NAME="file"
PKG_CATEGORY="base"
PKG_VERSION="5.46"
PKG_DESC="file(1) e libmagic - detecção de tipo de arquivo por conteúdo"
PKG_HOMEPAGE="https://www.darwinsys.com/file/"

PKG_SOURCE=(
    "https://astron.com/pub/file/file-5.46.tar.gz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "INSIRA_AQUI_O_SHA256_REAL_DO_FILE_5_46"
)

# Se quiser depender explicitamente de algo, declare aqui.
# PKG_DEPENDS=(
#     "sys-libs/glibc"
# )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
        "--libdir=/usr/lib"
        "--mandir=/usr/share/man"
    )

    # Integra com perfil (glibc/musl) via CHOST
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

    # Instala tudo em DESTDIR, o ADM depois copia pro ROOTFS
    make DESTDIR="$DESTDIR" install

    # Se quiser garantir o arquivo de banco de magic em local padrão:
    # Em geral já vai para /usr/share/misc/magic.mgc
    if [[ -f "$DESTDIR/usr/share/misc/magic.mgc" ]]; then
        :
    fi

    # Documentação básica
    install -d "$DESTDIR/usr/share/doc/file-$PKG_VERSION"
    for f in README COPYING ChangeLog NEWS AUTHORS; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/file-$PKG_VERSION/$f"
    done
}
