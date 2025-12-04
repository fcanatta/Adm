#!/usr/bin/env bash
# gcc-bootstrap.sh
# GCC "bootstrap" (Pass 1) para o adm
#
# Objetivo:
#   - Construir um cross-compiler inicial (C + C++) para TARGET_TRIPLET,
#     instalado em ${CROSS_PREFIX} (ex.: /cross-tools),
#     usando ${CROSS_SYSROOT} como sysroot.
#
# Requisitos:
#   - adm.sh fornece: SRC_DIR, DESTDIR, NUMJOBS (opcional)
#   - profile (glibc/musl) define: TARGET_TRIPLET, ADM_ROOTFS, PROFILE, etc.
#   - binutils-bootstrap já instalado para o mesmo TARGET_TRIPLET.

PKG_VERSION="15.2.0"

SRC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
SRC_MD5=""

pkg_build() {
    # Variáveis do adm:
    #   SRC_DIR  -> diretório do source do GCC já extraído
    #   DESTDIR  -> raiz fake usada para "make install"
    #   NUMJOBS  -> opcional, número de jobs
    cd "$SRC_DIR"

    # ========================================================
    # 1. Incorporar MPFR, GMP, MPC ao tree do GCC (estilo LFS)
    # ========================================================

    local MPFR_VER="4.2.2"
    local GMP_VER="6.3.0"
    local MPC_VER="1.3.1"

    local MPFR_TAR="mpfr-${MPFR_VER}.tar.xz"
    local GMP_TAR="gmp-${GMP_VER}.tar.xz"
    local MPC_TAR="mpc-${MPC_VER}.tar.gz"

    _fetch_if_missing() {
        local url="$1"
        local out="$2"

        if [[ -f "../$out" ]]; then
            return 0
        fi

        echo ">> Baixando $out de $url"
        if command -v curl >/dev/null 2>&1; then
            curl -L -o "../$out" "$url"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "../$out" "$url"
        else
            echo "ERRO: nem curl nem wget encontrados para baixar $out"
            exit 1
        fi
    }

    _fetch_if_missing "https://ftp.gnu.org/gnu/mpfr/${MPFR_TAR}" "$MPFR_TAR"
    _fetch_if_missing "https://ftp.gnu.org/gnu/gmp/${GMP_TAR}"   "$GMP_TAR"
    _fetch_if_missing "https://ftp.gnu.org/gnu/mpc/${MPC_TAR}"   "$MPC_TAR"

    if [[ ! -d mpfr ]]; then
        tar -xf "../${MPFR_TAR}"
        mv -v "mpfr-${MPFR_VER}" mpfr
    fi

    if [[ ! -d gmp ]]; then
        tar -xf "../${GMP_TAR}"
        mv -v "gmp-${GMP_VER}" gmp
    fi

    if [[ ! -d mpc ]]; then
        tar -xf "../${MPC_TAR}"
        mv -v "mpc-${MPC_VER}" mpc
    fi

    # ========================================================
    # 2. Ajuste lib64->lib em x86_64 (mesmo hack do LFS)
    # ========================================================

    case "$(uname -m)" in
        x86_64)
            sed -e '/m64=/s/lib64/lib/' \
                -i gcc/config/i386/t-linux64
        ;;
    esac

    # ========================================================
    # 3. TARGET_TRIPLET, ADM_ROOTFS, CROSS_SYSROOT, CROSS_PREFIX
    # ========================================================

    : "${TARGET_TRIPLET:=}"

    if [[ -z "$TARGET_TRIPLET" ]]; then
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            TARGET_TRIPLET="$(./config.guess 2>/dev/null || echo unknown-unknown-linux-gnu)"
        fi
    fi

    echo ">> GCC bootstrap alvo: ${TARGET_TRIPLET}"

    : "${ADM_ROOTFS:=/}"
    case "$ADM_ROOTFS" in
        /) ;;
        */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
    esac

    : "${CROSS_SYSROOT:=${ADM_ROOTFS}}"
    : "${CROSS_PREFIX:=/cross-tools}"

    echo ">> CROSS_SYSROOT  = ${CROSS_SYSROOT}"
    echo ">> CROSS_PREFIX   = ${CROSS_PREFIX}"

    # ========================================================
    # 4. Flags e opções de glibc/musl
    # ========================================================

    : "${NUMJOBS:=1}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    local glibc_opt=()
    case "${PROFILE:-glibc}" in
        glibc)
            local _glibc_ver="${GLIBC_TARGET_VERSION:-2.42}"
            glibc_opt=( "--with-glibc-version=${_glibc_ver}" )
        ;;
        *)
            # musl ou outros: não usa --with-glibc-version
        ;;
    esac

    # ========================================================
    # 5. Build em diretório separado
    # ========================================================

    rm -rf build
    mkdir -v build
    cd       build

    ../configure \
        --target="${TARGET_TRIPLET}" \
        --prefix="${CROSS_PREFIX}" \
        --with-sysroot="${CROSS_SYSROOT}" \
        "${glibc_opt[@]}" \
        --with-newlib \
        --without-headers \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdcxx \
        --enable-languages=c,c++

    make -j"${NUMJOBS}"

    # Instala no DESTDIR (o adm depois empacota)
    make DESTDIR="${DESTDIR}" install

    # IMPORTANTE: não geramos limits.h aqui.
    # Isso será feito em um hook de pós-instalação,
    # quando o gcc já estiver instalado dentro do ADM_ROOTFS.
}
