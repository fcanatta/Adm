# /opt/adm/packages/dev-lang/python/python.sh
#!/usr/bin/env bash

PKG_NAME="python"
PKG_CATEGORY="dev-lang"
PKG_VERSION="3.14.0"
PKG_DESC="Python 3.14 - linguagem de programação de alto nível, interpretada"
PKG_HOMEPAGE="https://www.python.org/"

PKG_SOURCE=(
    "https://www.python.org/ftp/python/3.14.0/Python-3.14.0.tar.xz"
)

PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "INSIRA_AQUI_O_SHA256_REAL_DO_PYTHON_3_14_0"
)

# Exemplo de dependências (ajuste conforme sua árvore ADM):
# PKG_DEPENDS=(
#     "sys-libs/zlib"
#     "sys-libs/openssl"
#     "sys-libs/ncurses"
#     "sys-libs/readline"
# )

pkg_build() {
    cd "$SRC_DIR"

    local conf_opts=(
        "--prefix=/usr"
        "--enable-shared"
        "--with-ensurepip=yes"
        "--enable-ipv6"
    )

    # Integra com o profile (glibc/musl) via CHOST
    if [[ -n "${CHOST:-}" ]]; then
        conf_opts+=("--host=$CHOST")
        if [[ -x "./config.guess" ]]; then
            conf_opts+=("--build=$(./config.guess)")
        fi
    fi

    # Usa CC/CFLAGS/LDFLAGS do profile (glibc.profile/musl.profile)
    ./configure "${conf_opts[@]}"
    make
}

pkg_install() {
    cd "$SRC_DIR"

    # Instala em DESTDIR; o ADM depois aplica no ROOTFS
    make DESTDIR="$DESTDIR" install

    # Nome padrão do binário principal esperado: python3.14
    # Garante symlinks convenientes
    if [[ -x "$DESTDIR/usr/bin/python3.14" ]]; then
        ( cd "$DESTDIR/usr/bin"
          ln -sf python3.14 python3
          ln -sf python3 python
        )
    fi

    # Documentação básica
    install -d "$DESTDIR/usr/share/doc/python-$PKG_VERSION"
    for f in README* LICENSE* Misc/NEWS*; do
        [[ -f "$f" ]] || continue
        install -m 644 "$f" "$DESTDIR/usr/share/doc/python-$PKG_VERSION/$(basename "$f")"
    done
}
