#!/usr/bin/env bash
# libtool-2.5.4.sh
#
# Pacote: GNU Libtool 2.5.4
#
# Objetivo:
#   - Construir e instalar o libtool-2.5.4 no sistema alvo via adm,
#     com destino final em /usr dentro do ADM_ROOTFS.
#
# Integração com adm:
#   - Usa:
#       SRC_DIR  -> diretório com o código-fonte extraído (libtool-2.5.4)
#       DESTDIR  -> raiz fake usada para "make install"
#       NUMJOBS  -> número de jobs (opcional)
#   - Respeita TARGET_TRIPLET se definido (cross/nativo).
#
# Dependências:
#   - autoconf
#   - automake
#   - m4
#   - perl

PKG_VERSION="2.5.4"

SRC_URL="https://ftp.gnu.org/gnu/libtool/libtool-${PKG_VERSION}.tar.xz"
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
            if [[ -x "./build-aux/config.guess" ]]; then
                TARGET_TRIPLET="$(./build-aux/config.guess)"
            else
                TARGET_TRIPLET="$(./config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
            fi
        fi
    fi

    echo ">> libtool-${PKG_VERSION} host/target: ${TARGET_TRIPLET}"

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

    export CFLAGS
    export CXXFLAGS

    # Se quiser forçar cross, descomente:
    # export CC="${TARGET_TRIPLET}-gcc"

    # Determinar BUILD/HOST
    if [[ -x "./build-aux/config.guess" ]]; then
        BUILD_TRIPLET="$(./build-aux/config.guess)"
    else
        BUILD_TRIPLET="$(./config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
    fi
    HOST_TRIPLET="${TARGET_TRIPLET}"

    echo ">> BUILD_TRIPLET = ${BUILD_TRIPLET}"
    echo ">> HOST_TRIPLET  = ${HOST_TRIPLET}"

    # Aviso sobre perl
    if ! command -v perl >/dev/null 2>&1; then
        echo "AVISO: 'perl' não encontrado no PATH."
        echo "       Vários scripts do libtool dependem de perl em runtime."
    fi

    # ===========================================
    # 3. Diretório de build separado
    # ===========================================

    rm -rf build
    mkdir -v build
    cd       build

    # ===========================================
    # 4. Configure do libtool
    # ===========================================
    #
    # Opções:
    #   --prefix=/usr
    #   --build/--host
    #   --disable-static        -> evita libs estáticas desnecessárias
    #   --enable-ltdl-install   -> instala libltdl como biblioteca de sistema

    ../configure \
        --prefix=/usr \
        --build="${BUILD_TRIPLET}" \
        --host="${HOST_TRIPLET}" \
        --disable-static \
        --enable-ltdl-install

    # ===========================================
    # 5. Compilar e instalar em DESTDIR
    # ===========================================

    echo ">> Compilando libtool-${PKG_VERSION} ..."
    make -j"${NUMJOBS}"

    echo ">> (Opcional) Rodando 'make check' do libtool..."
    echo "    (Pode ser demorado; comente isto se quiser acelerar.)"
    if ! make -k check; then
        echo "AVISO: 'make check' do libtool encontrou falhas."
        echo "       Revise os logs se necessário; seguindo com instalação."
    fi

    echo ">> Instalando libtool-${PKG_VERSION} em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # Em geral, instala:
    #   /usr/bin/libtool
    #   /usr/bin/libtoolize
    #   /usr/lib/libltdl.so*
    #   /usr/lib/libltdl.la
    #   /usr/include/ltdl.h
    #   /usr/share/aclocal/libtool.m4, ltdl.m4

    echo ">> libtool-${PKG_VERSION} construído e instalado em DESTDIR=${DESTDIR}."
}
