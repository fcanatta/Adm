#!/usr/bin/env bash
# gcc-15.2.0.sh
#
# GCC "final" para o sistema alvo, integrado ao adm.
#
# Diferença para o gcc-bootstrap:
#   - prefix = /usr (sistema final)
#   - usa headers + libc (glibc ou musl) já instalados no ADM_ROOTFS
#   - constrói o compilador completo (C e C++) para TARGET_TRIPLET
#   - não precisa de --without-headers / --with-newlib
#
# Pré-requisitos no ADM_ROOTFS:
#   - linux-headers em /usr/include
#   - libc instalada (glibc-2.42 OU musl-1.2.x) com stdio.h etc.
#   - libstdc++-15.2.0 já instalada (ou você pode deixar o GCC construir
#     a própria libstdc++ e então remover o pacote separado, se preferir)

PKG_VERSION="15.2.0"

SRC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
SRC_MD5=""

pkg_build() {
    # Variáveis fornecidas pelo adm:
    #   SRC_DIR  -> diretório do source do GCC já extraído (gcc-15.2.0)
    #   DESTDIR  -> raiz fake usada para 'make install'
    #   NUMJOBS  -> opcional, número de jobs
    cd "$SRC_DIR"

    # ==========================================================
    # 1. Incorporar MPFR, GMP, MPC (como no bootstrap)
    # ==========================================================

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

    # ==========================================================
    # 2. Ajuste lib64->lib para x86_64 (mesmo hack do LFS)
    # ==========================================================

    case "$(uname -m)" in
        x86_64)
            sed -e '/m64=/s/lib64/lib/' \
                -i gcc/config/i386/t-linux64
        ;;
    esac

    # ==========================================================
    # 3. TARGET_TRIPLET, ADM_ROOTFS, CROSS_SYSROOT
    # ==========================================================

    : "${TARGET_TRIPLET:=}"

    if [[ -z "$TARGET_TRIPLET" ]]; then
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            TARGET_TRIPLET="$(./config.guess 2>/dev/null || echo unknown-unknown-linux-gnu)"
        fi
    fi

    echo ">> GCC final alvo: ${TARGET_TRIPLET}"

    : "${ADM_ROOTFS:=/}"
    case "$ADM_ROOTFS" in
        /) ;;
        */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
    esac

    : "${CROSS_SYSROOT:=${ADM_ROOTFS}}"

    echo ">> ADM_ROOTFS    = ${ADM_ROOTFS}"
    echo ">> CROSS_SYSROOT = ${CROSS_SYSROOT}"

    # ==========================================================
    # 4. Verificar headers + libc no sysroot
    # ==========================================================

    if [[ ! -d "${CROSS_SYSROOT}/usr/include" ]]; then
        echo "ERRO: ${CROSS_SYSROOT}/usr/include não existe."
        echo "      Instale linux-headers e a libc antes (glibc/musl)."
        exit 1
    fi

    if [[ ! -f "${CROSS_SYSROOT}/usr/include/stdio.h" ]]; then
        echo "ERRO: ${CROSS_SYSROOT}/usr/include/stdio.h não existe."
        echo "      A libc do alvo não parece instalada corretamente."
        exit 1
    fi

    # ==========================================================
    # 5. Flags, BUILD/HOST, glibc/musl
    # ==========================================================

    : "${NUMJOBS:=1}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    # Compiladores de bootstrap/finais para o alvo (devem existir)
    export CC="${TARGET_TRIPLET}-gcc"
    export CXX="${TARGET_TRIPLET}-g++"
    export AR="${TARGET_TRIPLET}-ar"
    export RANLIB="${TARGET_TRIPLET}-ranlib"

    if ! command -v "$CC" >/dev/null 2>&1; then
        echo "ERRO: Não encontrei '${CC}' no PATH."
        echo "      Instale/configure o GCC de bootstrap/final primeiro."
        exit 1
    fi
    if ! command -v "$CXX" >/dev/null 2>&1; then
        echo "ERRO: Não encontrei '${CXX}' no PATH."
        echo "      Instale/configure o GCC C++ de bootstrap/final primeiro."
        exit 1
    fi

    BUILD_TRIPLET="$("$SRC_DIR"/config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
    HOST_TRIPLET="${TARGET_TRIPLET}"

    echo ">> BUILD_TRIPLET = ${BUILD_TRIPLET}"
    echo ">> HOST_TRIPLET  = ${HOST_TRIPLET}"

    # Opção extra para glibc (informação de versão)
    local glibc_opt=()
    case "${PROFILE:-glibc}" in
        glibc)
            local _glibc_ver="${GLIBC_TARGET_VERSION:-2.42}"
            glibc_opt=( "--with-glibc-version=${_glibc_ver}" )
        ;;
        *)
            # musl/other: não usa --with-glibc-version
        ;;
    esac

    # ==========================================================
    # 6. Diretório de build separado
    # ==========================================================

    rm -rf build-final
    mkdir -v build-final
    cd       build-final

    # ==========================================================
    # 7. Configure do GCC final
    # ==========================================================
    #
    # Opções padrão inspiradas em distros/LFS:
    #   --prefix=/usr
    #   --target = TARGET_TRIPLET
    #   --with-sysroot = CROSS_SYSROOT
    #   --enable-languages=c,c++
    #   --enable-default-pie, --enable-default-ssp
    #   --disable-multilib
    #   --with-system-zlib
    #   --disable-bootstrap (não fazer auto-bootstrap do GCC no próprio build)

    ../configure \
        --prefix=/usr \
        --build="${BUILD_TRIPLET}" \
        --host="${HOST_TRIPLET}" \
        --target="${TARGET_TRIPLET}" \
        --with-sysroot="${CROSS_SYSROOT}" \
        "${glibc_opt[@]}" \
        --enable-languages=c,c++ \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-multilib \
        --disable-bootstrap \
        --with-system-zlib \
        --disable-libsanitizer

    # Se você quiser manter libstdc++ separada (pacote libstdc++-15.2.0)
    # pode desabilitar libstdcxx aqui. POR PADRÃO, vamos deixar GCC construir
    # sua própria libstdc++, e você decide se mantém o pacote separado ou não.
    #
    # Para desabilitar, adicione:
    #   --disable-libstdcxx
    #
    # no configure acima.

    # ==========================================================
    # 8. Compilar e instalar em DESTDIR
    # ==========================================================

    echo ">> Compilando GCC ${PKG_VERSION} (final)..."
    make -j"${NUMJOBS}"

    echo ">> Instalando GCC ${PKG_VERSION} em DESTDIR=${DESTDIR}..."
    make DESTDIR="${DESTDIR}" install

    # Opcional: remover headers/files antigos de bootstrap, etc.
    # (melhor fazer isso num pacote separado de limpeza, se quiser.)

    echo ">> GCC ${PKG_VERSION} final construído e instalado em DESTDIR=${DESTDIR}."
}
