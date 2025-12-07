#!/usr/bin/env bash

PKG_NAME="coreutils"
PKG_CATEGORY="sys-apps"
PKG_VERSION="9.9"
PKG_DESC="GNU Coreutils - ferramentas básicas de manipulação de arquivos, texto e sistema"
PKG_HOMEPAGE="https://www.gnu.org/software/coreutils/"

PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/coreutils/coreutils-9.9.tar.gz"
)

# ATENÇÃO: coloque aqui o SHA-256 real do tarball coreutils-9.9.tar.gz
# Exemplo de placeholder, troque pelo valor correto que você obtiver com sha256sum:
PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "INSIRA_AQUI_O_SHA256_REAL_DO_COREUTILS_9_9"
)

# Dependências explícitas (ajuste conforme a tua árvore):
# PKG_DEPENDS=(
#     "sys-libs/ncurses"
#     "sys-libs/glibc"    # ou equivalente no teu ADM
# )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
        "--libdir=/usr/lib"
        "--mandir=/usr/share/man"
        "--infodir=/usr/share/info"
        "--enable-no-install-program=kill,uptime"  # opcional, estilo LFS
    )

    # Integra com o profile glibc/musl via CHOST
    if [[ -n "${CHOST:-}" ]]; then
        conf_opts+=("--host=$CHOST")
        if [[ -x "./build-aux/config.guess" ]]; then
            conf_opts+=("--build=$(./build-aux/config.guess)")
        fi
    fi

    # Você pode customizar CFLAGS/CXXFLAGS/LDFLAGS via profiles glibc.profile/musl.profile
    ./configure "${conf_opts[@]}"
    make
}

pkg_install() {
    cd "$SRC_DIR"

    # Instala tudo em DESTDIR (o ADM depois joga no ROOTFS)
    make DESTDIR="$DESTDIR" install

    # Normalmente, em sistemas com /usr-merge, alguns utilitários podem precisar ir em /bin
    # Caso queira garantir /bin/coreutils principais, faça alguns links (opcional):
    install -d "$DESTDIR/bin"

    for bin in cat chgrp chmod chown cp date dd df echo false ln ls mkdir mknod \
               mv pwd rm rmdir stty sync true uname; do
        if [[ -x "$DESTDIR/usr/bin/$bin" && ! -e "$DESTDIR/bin/$bin" ]]; then
            ln -sf "../usr/bin/$bin" "$DESTDIR/bin/$bin"
        fi
    done

    # Documentação básica
    if [[ -d "doc" ]]; then
        install -d "$DESTDIR/usr/share/doc/coreutils-$PKG_VERSION"
        cp -av doc/* "$DESTDIR/usr/share/doc/coreutils-$PKG_VERSION"/
    fi
}
