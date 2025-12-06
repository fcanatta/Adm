# Linux-6.17.9 API Headers para o ADM

PKG_NAME="linux-api-headers"
PKG_CATEGORY="core"
PKG_VERSION="6.17.9"
PKG_DESC="Linux ${PKG_VERSION} API headers sanitizados para Glibc e userland"
PKG_HOMEPAGE="https://www.kernel.org/"

# Fonte oficial do kernel 6.17.9 0
PKG_SOURCE=(
  "https://www.kernel.org/pub/linux/kernel/v6.x/linux-6.17.9.tar.xz"
)

# MD5 retirado do LFS para linux-6.17.9.tar.xz 1
PKG_CHECKSUM_TYPE="md5"
PKG_CHECKSUMS=(
  "512f1c964520792d9337f43b9177b181"
)

# Só usa ferramentas base (make, find, cp, etc)
PKG_DEPENDS=()

# ---------------------------------------------------
# Build: gera os headers API sanitizados
# Baseado nas instruções do Linux From Scratch:
#   make mrproper
#   make headers
#   find usr/include -type f ! -name '*.h' -delete 2
# ---------------------------------------------------
pkg_build() {
    # Garante árvore limpa
    make mrproper

    # Gera os headers em usr/include
    make headers

    # Remove qualquer arquivo que não seja .h em usr/include
    find usr/include -type f ! -name '*.h' -delete
}

# ---------------------------------------------------
# Install: copia headers para $DESTDIR/usr/include
# O ADM depois faz rsync desse DESTDIR para o ROOTFS.
# ---------------------------------------------------
pkg_install() {
    mkdir -p "$DESTDIR/usr"
    # Resultado final: $DESTDIR/usr/include/{linux,asm,...}
    cp -rv usr/include "$DESTDIR/usr/"
}
