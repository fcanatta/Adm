#!/usr/bin/env bash
# binutils-bootstrap.sh
# Binutils "bootstrap"/cross inicial para o adm
#
# Objetivo:
#   - Construir um binutils mínimo para o TARGET_TRIPLET,
#     instalado em ${CROSS_PREFIX} (ex.: /cross-tools),
#     usando ${CROSS_SYSROOT} como sysroot.
#
# Requisitos:
#   - adm.sh fornece: SRC_DIR, DESTDIR, NUMJOBS (opcional)
#   - profile (glibc/musl) define: TARGET_TRIPLET, ADM_ROOTFS, etc.

PKG_VERSION="2.45.1"

# Fonte oficial GNU (tarball .tar.xz)
SRC_URL="https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
SRC_MD5=""   # deixe vazio se não usar checagem md5

pkg_build() {
    # Variáveis do adm:
    #   SRC_DIR  -> diretório com o código-fonte já extraído
    #   DESTDIR  -> raiz fake para "make install"
    #   NUMJOBS  -> paralelismo (opcional)
    cd "$SRC_DIR"

    # ===========================
    #  Alvo e sysroot
    # ===========================

    # TARGET_TRIPLET vem do profile (ex.: x86_64-pc-linux-gnu, x86_64-linux-musl)
    : "${TARGET_TRIPLET:=}"

    if [[ -z "$TARGET_TRIPLET" ]]; then
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            TARGET_TRIPLET="$(./config.guess 2>/dev/null || echo unknown-unknown-linux-gnu)"
        fi
    fi

    echo ">> Binutils bootstrap alvo: ${TARGET_TRIPLET}"

    # Root do sistema alvo (onde o sysroot físico existe)
    : "${ADM_ROOTFS:=/}"
    case "$ADM_ROOTFS" in
        /) ;;
        */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
    esac

    # CROSS_SYSROOT: root lógico que o binutils vai usar
    : "${CROSS_SYSROOT:=${ADM_ROOTFS}}"

    # CROSS_PREFIX: onde o cross/binutils será instalado dentro do root alvo
    : "${CROSS_PREFIX:=/cross-tools}"

    echo ">> CROSS_SYSROOT  = ${CROSS_SYSROOT}"
    echo ">> CROSS_PREFIX   = ${CROSS_PREFIX}"

    # ===========================
    #  Flags e paralelismo
    # ===========================

    : "${NUMJOBS:=1}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    # ===========================
    #  Build em diretório separado
    # ===========================

    rm -rf build
    mkdir -v build
    cd       build

    ../configure \
        --prefix="${CROSS_PREFIX}" \
        --with-sysroot="${CROSS_SYSROOT}" \
        --target="${TARGET_TRIPLET}" \
        --disable-nls \
        --disable-werror \
        --enable-new-dtags \
        --enable-default-hash-style=gnu \
        --enable-gprofng=no

    make -j"${NUMJOBS}"

    # Instala em DESTDIR; o adm depois empacota esse DESTDIR.
    make DESTDIR="${DESTDIR}" install
}
