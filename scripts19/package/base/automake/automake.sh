#!/usr/bin/env bash
# automake-1.18.1.sh
#
# Pacote: GNU Automake 1.18.1
#
# Objetivo:
#   - Construir e instalar o automake-1.18.1 no sistema alvo via adm,
#     com destino final em /usr dentro do ADM_ROOTFS.
#
# Integração com adm:
#   - Usa:
#       SRC_DIR  -> diretório com o código-fonte extraído (automake-1.18.1)
#       DESTDIR  -> raiz fake usada para "make install"
#       NUMJOBS  -> número de jobs (opcional, mas automake é rápido)
#   - Respeita TARGET_TRIPLET se definido (cross/nativo).
#
# Dependências:
#   - perl (necessário em tempo de execução)
#   - m4, autoconf, make, etc. para uso em builds de outros pacotes.

PKG_VERSION="1.18.1"

SRC_URL="https://ftp.gnu.org/gnu/automake/automake-${PKG_VERSION}.tar.xz"
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
        # Se não foi setado, tentamos HOST ou config.guess
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

    echo ">> automake-${PKG_VERSION} host/target: ${TARGET_TRIPLET}"

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

    # Se quiser forçar cross, pode descomentar:
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

    # Ver aviso sobre perl
    if ! command -v perl >/dev/null 2>&1; then
        echo "AVISO: 'perl' não encontrado no PATH."
        echo "       O automake instala, mas boa parte dos scripts dele dependem de perl."
    fi

    # ===========================================
    # 3. Diretório de build separado
    # ===========================================

    rm -rf build
    mkdir -v build
    cd       build

    # ===========================================
    # 4. Configure do automake
    # ===========================================
    #
    # Opções:
    #   --prefix=/usr
    #   --build/--host
    #
    # Automake é inteiramente em scripts (perl + shell), então é bem tranquilo.

    ../configure \
        --prefix=/usr \
        --build="${BUILD_TRIPLET}" \
        --host="${HOST_TRIPLET}"

    # ===========================================
    # 5. Compilar e instalar em DESTDIR
    # ===========================================

    echo ">> Compilando automake-${PKG_VERSION} ..."
    make -j"${NUMJOBS}"

    echo ">> Instalando automake-${PKG_VERSION} em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # Por padrão, ele instala:
    #   /usr/bin/automake
    #   /usr/bin/aclocal
    #   /usr/share/automake-1.xx/*
    #   /usr/share/aclocal/*
    #
    # Se quiser mover docs pra /usr/share/doc/automake-${PKG_VERSION}, faça aqui.

    echo ">> automake-${PKG_VERSION} construído e instalado em DESTDIR=${DESTDIR}."
}
