#!/usr/bin/env bash
# readline-8.3.sh
#
# Pacote: GNU Readline 8.3
#
# Objetivo:
#   - Construir e instalar o readline-8.3 no sistema alvo via adm,
#     com destino final em /usr dentro do ADM_ROOTFS.
#
# Integração com adm:
#   - Usa:
#       SRC_DIR  -> diretório com o código-fonte extraído (readline-8.3)
#       DESTDIR  -> raiz fake usada para "make install"
#       NUMJOBS  -> número de jobs (opcional)
#   - Respeita TARGET_TRIPLET se definido (cross/nativo).
#
# Dependências:
#   - ncurses (widec) ou termcap compatível.
#
# Notas:
#   - Instala bibliotecas compartilhadas (libreadline.so, libhistory.so).
#   - Headers em /usr/include/readline/*.

PKG_VERSION="8.3"

SRC_URL="https://ftp.gnu.org/gnu/readline/readline-${PKG_VERSION}.tar.gz"
SRC_MD5=""

pkg_build() {
    # Variáveis fornecidas pelo adm:
    #   SRC_DIR, DESTDIR, NUMJOBS
    cd "$SRC_DIR"

    # ===========================================
    # 1. TARGET_TRIPLET, ADM_ROOTFS (informativo)
    # ===========================================

    : "${TARGET_TRIPLET:=}"

    if [[ -z "$TARGET_TRIPLET" ]]; then
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            if [[ -x "./support/config.guess" ]]; then
                TARGET_TRIPLET="$(./support/config.guess)"
            else
                TARGET_TRIPLET="$(uname -m)-unknown-linux-gnu"
            fi
        fi
    fi

    echo ">> readline-${PKG_VERSION} host/target: ${TARGET_TRIPLET}"

    : "${ADM_ROOTFS:=/}"
    case "$ADM_ROOTFS" in
        /) ;;
        */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
    esac
    echo ">> ADM_ROOTFS = ${ADM_ROOTFS}"

    # ===========================================
    # 2. Flags padrão e ambiente
    # ===========================================

    : "${NUMJOBS:=1}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    # Linkar contra ncursesw (o que você já tem)
    # Ajuste se você usar outro backend de termcap.
    CFLAGS="${CFLAGS} -I/usr/include"
    LDFLAGS="${LDFLAGS:-} -L/usr/lib"
    LIBS="${LIBS:-} -lncursesw"

    export CFLAGS
    export CXXFLAGS
    export LDFLAGS
    export LIBS

    # Se quiser forçar cross:
    # export CC="${TARGET_TRIPLET}-gcc"

    # Determinar BUILD/HOST
    if [[ -x "./support/config.guess" ]]; then
        BUILD_TRIPLET="$(./support/config.guess)"
    else
        BUILD_TRIPLET="$(uname -m)-unknown-linux-gnu"
    fi
    HOST_TRIPLET="${TARGET_TRIPLET}"

    echo ">> BUILD_TRIPLET = ${BUILD_TRIPLET}"
    echo ">> HOST_TRIPLET  = ${HOST_TRIPLET}"

    # ===========================================
    # 3. Diretório de build separado
    # ===========================================

    rm -rf build
    mkdir -v build
    cd       build

    # ===========================================
    # 4. Configure do readline
    # ===========================================
    #
    # Opções:
    #   --prefix=/usr
    #   --build/--host
    #   --disable-static (opcional, se não quiser .a)
    #

    ../configure \
        --prefix=/usr \
        --build="${BUILD_TRIPLET}" \
        --host="${HOST_TRIPLET}" \
        --disable-static

    # ===========================================
    # 5. Compilar e instalar em DESTDIR
    # ===========================================

    echo ">> Compilando readline-${PKG_VERSION} ..."
    make -j"${NUMJOBS}"

    echo ">> Instalando readline-${PKG_VERSION} em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # Normalmente instala:
    #   /usr/lib/libreadline.so*
    #   /usr/lib/libhistory.so*
    #   /usr/include/readline/*.h

    echo ">> readline-${PKG_VERSION} construído e instalado em DESTDIR=${DESTDIR}."
}
