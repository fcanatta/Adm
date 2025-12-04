#!/usr/bin/env bash
# libstdc++-15.2.0.sh
#
# Libstdc++ "final" do GCC-15.2.0 para o sistema alvo.
#
# Objetivo:
#   - Construir e instalar a libstdc++ (C++) a partir do source do GCC,
#     para o TARGET_TRIPLET, instalando em /usr dentro do ADM_ROOTFS
#     (via DESTDIR).
#
# Pré-requisitos:
#   - glibc (ou musl) já instalada no ADM_ROOTFS
#   - linux-headers já instalados em ${ADM_ROOTFS}/usr/include
#   - um GCC para o alvo disponível (bootstrap ou final) como:
#       ${TARGET_TRIPLET}-gcc
#       ${TARGET_TRIPLET}-g++
#
# Observação:
#   - Este pacote cuida APENAS do libstdc++-v3. O GCC em si
#     pode ser outro pacote (gcc-final, por exemplo).

PKG_VERSION="15.2.0"

# Reaproveitamos o tarball oficial do GCC; libstdc++ faz parte dele.
SRC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
SRC_MD5=""

pkg_build() {
    # Variáveis fornecidas pelo adm:
    #   SRC_DIR  -> diretório do source do GCC já extraído (gcc-15.2.0)
    #   DESTDIR  -> raiz fake para 'make install'
    #   NUMJOBS  -> opcional, número de jobs
    cd "$SRC_DIR"

    # ============================================================
    # 1. TARGET_TRIPLET, ADM_ROOTFS, CROSS_SYSROOT
    # ============================================================

    : "${TARGET_TRIPLET:=}"

    if [[ -z "$TARGET_TRIPLET" ]]; then
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            TARGET_TRIPLET="$(./config.guess 2>/dev/null || echo unknown-unknown-linux-gnu)"
        fi
    fi

    echo ">> Libstdc++ final alvo: ${TARGET_TRIPLET}"

    : "${ADM_ROOTFS:=/}"
    case "$ADM_ROOTFS" in
        /) ;;
        */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
    esac

    : "${CROSS_SYSROOT:=${ADM_ROOTFS}}"

    echo ">> ADM_ROOTFS    = ${ADM_ROOTFS}"
    echo ">> CROSS_SYSROOT = ${CROSS_SYSROOT}"

    # ============================================================
    # 2. Verificar toolchain e headers básicos
    # ============================================================

    if [[ ! -d "${CROSS_SYSROOT}/usr/include" ]]; then
        echo "ERRO: ${CROSS_SYSROOT}/usr/include não existe."
        echo "      Instale primeiro linux-headers e a libc (glibc/musl)."
        exit 1
    fi

    if [[ ! -f "${CROSS_SYSROOT}/usr/include/stdio.h" ]]; then
        echo "ERRO: ${CROSS_SYSROOT}/usr/include/stdio.h não existe."
        echo "      A libc do alvo não parece instalada corretamente."
        exit 1
    fi

    # Compilador do alvo (deve existir)
    : "${NUMJOBS:=1}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    export CC="${TARGET_TRIPLET}-gcc"
    export CXX="${TARGET_TRIPLET}-g++"
    export AR="${TARGET_TRIPLET}-ar"
    export RANLIB="${TARGET_TRIPLET}-ranlib"

    if ! command -v "$CC" >/dev/null 2>&1; then
        echo "ERRO: Não encontrei '${CC}' no PATH. Instale/configure o GCC para o alvo antes."
        exit 1
    fi

    if ! command -v "$CXX" >/dev/null 2>&1; then
        echo "ERRO: Não encontrei '${CXX}' no PATH. Instale/configure o GCC C++ para o alvo antes."
        exit 1
    fi

    echo ">> Usando CC=${CC}"
    echo ">> Usando CXX=${CXX}"

    # ============================================================
    # 3. Diretório de build dedicado para libstdc++-v3
    # ============================================================
    #
    # Evitamos misturar com outros builds de gcc.

    rm -rf build-libstdc++
    mkdir -v build-libstdc++
    cd       build-libstdc++

    # ============================================================
    # 4. Configure do libstdc++ (final)
    # ============================================================
    #
    # Padrão:
    #   --host  = TARGET_TRIPLET
    #   --build = config.guess
    #   --prefix= /usr
    #   --disable-multilib (simplifica)
    #   --disable-nls      (não precisamos de mensagem traduzida aqui)
    #
    # with-gxx-include-dir aponta para o diretório padrão onde o GCC
    # final espera encontrar os includes de C++ dentro do sysroot:
    #
    #   /usr/include/c++/15.2.0
    #
    # (sem CROSS_PREFIX, porque agora é "sistema final".)

    BUILD_TRIPLET="$("$SRC_DIR"/config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
    echo ">> BUILD_TRIPLET = ${BUILD_TRIPLET}"

    local gxx_inc_dir="/usr/include/c++/${PKG_VERSION}"

    echo ">> Diretório de includes C++ alvo: ${gxx_inc_dir}"

    ../libstdc++-v3/configure      \
        --host="${TARGET_TRIPLET}" \
        --build="${BUILD_TRIPLET}" \
        --prefix=/usr              \
        --disable-multilib         \
        --disable-nls              \
        --enable-shared            \
        --enable-threads=posix     \
        --enable-libstdcxx-time=yes \
        --with-gxx-include-dir="${gxx_inc_dir}"

    # ============================================================
    # 5. Compilar e instalar em DESTDIR
    # ============================================================

    make -j"${NUMJOBS}"

    echo ">> Instalando libstdc++ em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # Remover arquivos .la (não são úteis e atrapalham às vezes)
    echo ">> Removendo .la da libstdc++ ..."
    rm -v "${DESTDIR}/usr/lib/lib"{stdc++{,exp,fs},supc++}.la 2>/dev/null || true

    echo ">> libstdc++-${PKG_VERSION} construída e instalada em DESTDIR=${DESTDIR}."
}
