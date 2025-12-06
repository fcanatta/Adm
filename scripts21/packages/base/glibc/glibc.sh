#!/usr/bin/env bash

# Pacote: Glibc-2.42 (final)
# Perfil: glibc.profile (usa ROOTFS, CHOST, etc)

PKG_NAME="glibc"
PKG_CATEGORY="core"
PKG_VERSION="2.42"
PKG_DESC="GNU C Library 2.42 (glibc) - biblioteca C principal do sistema"
PKG_HOMEPAGE="https://www.gnu.org/software/libc/"

# Fontes:
#   - Tarball oficial
#   - Patch FHS do LFS
PKG_SOURCE=(
    "https://ftp.gnu.org/gnu/glibc/glibc-2.42.tar.xz"
    "https://www.linuxfromscratch.org/patches/downloads/glibc/glibc-2.42-fhs-1.patch"
)

# Usando SHA256 oficial do tarball (via Ubuntu orig.tar.xz) 
PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "d1775e32e4628e64ef930f435b67bb63af7599acb6be2b335b9f19f16509f17f"   # glibc-2.42.tar.xz
    "SKIP"                                                               # glibc-2.42-fhs-1.patch (sem checksum conhecido)
)

# Dependências de build/ordem dentro do ADM
PKG_DEPENDS=(
    "linux-api-headers"   # precisa de /usr/include do kernel no ROOTFS
)

pkg_build() {
    : "${SRC_DIR:?SRC_DIR não definido}"
    : "${BUILD_DIR:?BUILD_DIR não definido}"
    : "${ROOTFS:?ROOTFS não definido (ver glibc.profile)}"

    echo ">>> [glibc] ROOTFS=${ROOTFS}"
    echo ">>> [glibc] SRC_DIR=${SRC_DIR}"
    echo ">>> [glibc] BUILD_DIR=${BUILD_DIR}"

    # Confere headers do kernel no sysroot
    if [[ ! -f "${ROOTFS}/usr/include/linux/version.h" ]]; then
        echo "ERRO: Linux API headers não encontrados em ${ROOTFS}/usr/include."
        echo "      Instale o pacote core/linux-api-headers antes da Glibc."
        return 1
    fi

    cd "$SRC_DIR"

    # Patch FHS (ajusta /var/db etc) 
    if [[ -f ../glibc-2.42-fhs-1.patch ]]; then
        echo ">>> [glibc] Aplicando patch FHS..."
        patch -Np1 -i ../glibc-2.42-fhs-1.patch
    else
        echo "AVISO: ../glibc-2.42-fhs-1.patch não encontrado, prosseguindo sem FHS patch."
    fi

    # Fix abort.c (recomendado pelo LFS para evitar problemas com Valgrind) 
    sed -e '/unistd.h/i #include <string.h>' \
        -e '/libc_rwlock_init/c\
      __libc_rwlock_define_initialized (, reset_lock);\
      memcpy (&lock, &reset_lock, sizeof (lock));' \
        -i stdlib/abort.c

    # Diretório de build separado
    mkdir -pv "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Garante ldconfig/sln em /usr/sbin
    echo "rootsbindir=/usr/sbin" > configparms

    # Configuração principal (baseado no LFS 12.4) 
    ../configure \
        --prefix=/usr                   \
        --disable-werror                \
        --disable-nscd                  \
        --enable-kernel=5.4             \
        --enable-stack-protector=strong \
        libc_cv_slibdir=/usr/lib

    # Compila
    make

    # Se quiser rodar testes depois, você pode fazer manualmente:
    #   (cd "$BUILD_DIR" && make check)
    # Não coloco aqui por padrão pra não explodir tempo e falhar build inteiro
}

pkg_install() {
    : "${BUILD_DIR:?BUILD_DIR não definido}"
    : "${DESTDIR:?DESTDIR não definido}"

    cd "$BUILD_DIR"

    # Instala Glibc no DESTDIR (ADM sincroniza depois para o ROOTFS)
    make DESTDIR="$DESTDIR" install

    # Corrige path hardcoded no ldd (remove /usr do RTLDLIST) 
    if [[ -f "$DESTDIR/usr/bin/ldd" ]]; then
        sed -e '/RTLDLIST=/s@/usr@@g' -i "$DESTDIR/usr/bin/ldd"
    fi

    # Move scripts gdb *.py para diretório auto-load
    if compgen -G "$DESTDIR/usr/lib/*gdb.py" > /dev/null 2>&1; then
        echo ">>> [glibc] Ajustando scripts gdb de auto-load..."
        mkdir -pv "$DESTDIR/usr/share/gdb/auto-load/usr/lib"
        mv -v "$DESTDIR"/usr/lib/*gdb.py "$DESTDIR"/usr/share/gdb/auto-load/usr/lib/
    fi

    # Locales e /etc/nsswitch.conf, /etc/ld.so.conf, timezone etc
    # eu recomendo tratar em pacotes/configs separados, porque são bem opináveis.
}
