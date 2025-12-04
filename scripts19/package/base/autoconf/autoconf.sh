#!/usr/bin/env bash
# autoconf-2.72.sh
#
# Pacote: GNU Autoconf 2.72
#
# Objetivo:
#   - Construir e instalar o autoconf-2.72 no sistema alvo via adm,
#     com destino final em /usr dentro do ADM_ROOTFS.
#
# Integração com adm:
#   - Usa:
#       SRC_DIR  -> diretório com o código-fonte extraído (autoconf-2.72)
#       DESTDIR  -> raiz fake usada para "make install"
#       NUMJOBS  -> número de jobs (opcional)
#   - Respeita TARGET_TRIPLET se definido (cross/nativo).
#
# Dependências:
#   - perl (runtime)
#   - m4 (já instalado no root alvo de preferência)

PKG_VERSION="2.72"

SRC_URL="https://ftp.gnu.org/gnu/autoconf/autoconf-${PKG_VERSION}.tar.xz"
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

    echo ">> autoconf-${PKG_VERSION} host/target: ${TARGET_TRIPLET}"

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

    # Se quiser forçar cross:
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
        echo "       Autoconf vai instalar, mas scripts em runtime vão precisar de perl."
    fi

    # ===========================================
    # 3. Diretório de build separado
    # ===========================================

    rm -rf build
    mkdir -v build
    cd       build

    # ===========================================
    # 4. Configure do autoconf
    # ===========================================
    #
    # Ele é basicamente scripts + m4; bem tranquilo.

    ../configure \
        --prefix=/usr \
        --build="${BUILD_TRIPLET}" \
        --host="${HOST_TRIPLET}"

    # ===========================================
    # 5. Compilar e instalar em DESTDIR
    # ===========================================

    echo ">> Compilando autoconf-${PKG_VERSION} ..."
    make -j"${NUMJOBS}"

    echo ">> Instalando autoconf-${PKG_VERSION} em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # Normalmente instala:
    #   /usr/bin/autoconf
    #   /usr/bin/autoheader
    #   /usr/bin/autom4te
    #   /usr/share/autoconf/*
    #   /usr/share/autom4te-2.72/*

    echo ">> autoconf-${PKG_VERSION} construído e instalado em DESTDIR=${DESTDIR}."
}
