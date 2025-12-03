# Script de build para Libstdc++ a partir do GCC-15.2.0 (Pass 1) no admV2
# Baseado em LFS 5.6 "Libstdc++ from GCC-15.2.0", ajustado para o esquema:
#   - TARGET_TRIPLET
#   - ADM_ROOTFS
#   - CROSS_PREFIX / CROSS_SYSROOT
#   - DESTDIR do admV2
#
# Pré-requisitos (ambiente):
#   - binutils-2.45.1-pass1 instalado para TARGET_TRIPLET
#   - gcc-15.2.0-pass1 instalado para TARGET_TRIPLET (com --with-sysroot=CROSS_SYSROOT)
#   - glibc-2.42-pass1 instalada no sysroot (ADM_ROOTFS)
#   - Linux API headers já instalados em ${ADM_ROOTFS}/usr/include

PKG_VERSION="15.2.0"

# Reaproveitamos o tarball oficial do GCC (libstdc++ faz parte das fontes do GCC) 
SRC_URL="https://ftpmirror.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
SRC_MD5=""

pkg_build() {
    # Fornecido pelo admV2:
    #   SRC_DIR  -> diretório do source do GCC já extraído (gcc-15.2.0)
    #   DESTDIR  -> raiz fake do pacote (adm vai empacotar isso)
    #   NUMJOBS  -> jobs paralelos (se definido)
    cd "$SRC_DIR"

    # ------------------------------------------------------------------
    # 1. Determinar TARGET_TRIPLET, CROSS_PREFIX e CROSS_SYSROOT
    # ------------------------------------------------------------------

    : "${TARGET_TRIPLET:=}"

    if [[ -z "$TARGET_TRIPLET" ]]; then
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            TARGET_TRIPLET="$(./config.guess 2>/dev/null || echo unknown-unknown-linux-gnu)"
        fi
    fi

    echo ">> Libstdc++ Pass 1 alvo: ${TARGET_TRIPLET}"

    # Root real do sistema alvo (vem dos profiles / admV2)
    : "${ADM_ROOTFS:=/}"
    case "$ADM_ROOTFS" in
        /) ;;
        */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
    esac

    # Sysroot que o GCC pass1 usa para achar headers/libs do alvo
    : "${CROSS_SYSROOT:=${ADM_ROOTFS}}"

    # Prefixo do toolchain cross dentro do root do sistema alvo
    # (o mesmo usado no binutils/gcc pass1, ex.: /cross-tools)
    : "${CROSS_PREFIX:=/cross-tools}"

    echo ">> CROSS_SYSROOT  = ${CROSS_SYSROOT}"
    echo ">> CROSS_PREFIX   = ${CROSS_PREFIX}"

    # ------------------------------------------------------------------
    # 2. Diretório de build dedicado para libstdc++
    #    (LFS manda criar "build" separado dentro de gcc-15.2.0) 2
    # ------------------------------------------------------------------

    rm -rf build
    mkdir -v build
    cd       build

    # ------------------------------------------------------------------
    # 3. Configure do libstdc++ (adaptado do LFS 5.6) 3
    # ------------------------------------------------------------------
    #
    # No LFS original:
    #   ../libstdc++-v3/configure \
    #       --host=$LFS_TGT            \
    #       --build=$(../config.guess) \
    #       --prefix=/usr              \
    #       --disable-multilib         \
    #       --disable-nls              \
    #       --disable-libstdcxx-pch    \
    #       --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/15.2.0
    #
    # Aqui, adaptamos:
    #   - $LFS_TGT -> TARGET_TRIPLET
    #   - /tools/$LFS_TGT -> ${CROSS_PREFIX}/${TARGET_TRIPLET}
    #   - DESTDIR = DESTDIR do admV2 (ao invés de $LFS)

    local gxx_inc_dir="${CROSS_PREFIX}/${TARGET_TRIPLET}/include/c++/${PKG_VERSION}"

    echo ">> Diretório de includes C++ padrão esperado: ${gxx_inc_dir}"

    ../libstdc++-v3/configure      \
        --host="${TARGET_TRIPLET}" \
        --build="$(../config.guess)" \
        --prefix=/usr              \
        --disable-multilib         \
        --disable-nls              \
        --disable-libstdcxx-pch    \
        --with-gxx-include-dir="${gxx_inc_dir}"

    # ------------------------------------------------------------------
    # 4. Compilar libstdc++
    # ------------------------------------------------------------------

    : "${NUMJOBS:=1}"
    make -j"${NUMJOBS}"

    # ------------------------------------------------------------------
    # 5. Instalar em DESTDIR (vai virar pacote do admV2)
    # ------------------------------------------------------------------

    make DESTDIR="$DESTDIR" install

    # ------------------------------------------------------------------
    # 6. Remover arquivos .la que atrapalham cross-compilação 4
    # ------------------------------------------------------------------
    #
    # No LFS:
    #   rm -v $LFS/usr/lib/lib{stdc++{,exp,fs},supc++}.la
    #
    # Aqui fazemos o mesmo dentro do DESTDIR, para que nem entrem no pacote.

    rm -v "${DESTDIR}/usr/lib/lib"{stdc++{,exp,fs},supc++}.la 2>/dev/null || true
}
