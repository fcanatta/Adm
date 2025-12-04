#!/usr/bin/env bash
# python-3.14.0.sh
#
# Pacote: Python 3.14.0
#
# Objetivo:
#   - Construir e instalar o Python 3.14.0 no sistema alvo via adm,
#     com destino final em /usr dentro do ADM_ROOTFS.
#
# Integração com adm:
#   - Usa:
#       SRC_DIR  -> diretório com o código-fonte extraído (Python-3.14.0)
#       DESTDIR  -> raiz fake usada para "make install"
#       NUMJOBS  -> número de jobs (opcional)
#   - Respeita TARGET_TRIPLET se definido (cross/nativo).
#
# Notas:
#   - Usa --enable-optimizations e --with-lto (build mais pesado, mas melhor).
#   - Usa --enable-shared para ter libpython3.14.so em /usr/lib.
#   - Usa --with-ensurepip=install para já instalar pip no root alvo
#     (dentro de DESTDIR).

PKG_VERSION="3.14.0"

SRC_URL="https://www.python.org/ftp/python/${PKG_VERSION}/Python-${PKG_VERSION}.tar.xz"
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
            if [[ -x "./config.guess" ]]; then
                TARGET_TRIPLET="$(./config.guess)"
            else
                TARGET_TRIPLET="$(uname -m)-unknown-linux-gnu"
            fi
        fi
    fi

    echo ">> Python-${PKG_VERSION} host/target: ${TARGET_TRIPLET}"

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

    # Se quiser forçar cross/nativo:
    # export CC="${TARGET_TRIPLET}-gcc"
    # export CXX="${TARGET_TRIPLET}-g++"

    # Python costuma usar ./configure direto no source.
    # Ainda assim, podemos usar um build dir separado (melhor organização).

    # Determinar BUILD/HOST (informativo)
    if [[ -x "./config.guess" ]]; then
        BUILD_TRIPLET="$(./config.guess)"
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
    # 4. Configure do Python
    # ===========================================
    #
    # Opções principais:
    #   --prefix=/usr                -> binários e libs em /usr
    #   --enable-optimizations       -> PGO/LTO, deixa o Python mais rápido
    #   --with-lto                   -> link-time optimization
    #   --enable-shared              -> libpython3.14m.so em /usr/lib
    #   --with-ensurepip=install     -> instala pip junto
    #
    # Se você quiser um build mais rápido, pode remover
    # --enable-optimizations e --with-lto.

    ../configure \
        --prefix=/usr \
        --build="${BUILD_TRIPLET}" \
        --host="${HOST_TRIPLET}" \
        --enable-optimizations \
        --with-lto \
        --enable-shared \
        --with-ensurepip=install

    # ===========================================
    # 5. Compilar e instalar em DESTDIR
    # ===========================================

    echo ">> Compilando Python-${PKG_VERSION} ..."
    make -j"${NUMJOBS}"

    # Testes do Python podem ser MUITO demorados. Vamos deixar opcional.
    if [[ "${PYTHON_RUN_TESTS:-0}" = "1" ]]; then
        echo ">> Rodando 'make test' do Python (pode demorar MUITO)..."
        if ! make test; then
            echo "AVISO: 'make test' do Python encontrou falhas."
            echo "       Verifique os logs se necessário; prosseguindo com a instalação."
        fi
    else
        echo ">> Pulando 'make test' (defina PYTHON_RUN_TESTS=1 se quiser rodar)."
    fi

    echo ">> Instalando Python-${PKG_VERSION} em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # ===========================================
    # 6. Ajustes pós-instalação no DESTDIR
    # ===========================================
    #
    # Normalmente o Python instala algo como:
    #   /usr/bin/python3.14
    #   /usr/bin/python3
    #   /usr/lib/libpython3.14.so
    #   /usr/lib/python3.14/*
    #
    # Se você quiser garantir alguns symlinks, pode fazê-los aqui.

    PY_BIN_DIR="${DESTDIR}/usr/bin"

    if [[ -x "${PY_BIN_DIR}/python3.14" && ! -e "${PY_BIN_DIR}/python3" ]]; then
        echo ">> Criando symlink python3 -> python3.14 em ${PY_BIN_DIR}..."
        ln -svf python3.14 "${PY_BIN_DIR}/python3"
    fi

    # pip: certifique que pip3 aponta para pip3.14 se existir
    if [[ -x "${PY_BIN_DIR}/pip3.14" && ! -e "${PY_BIN_DIR}/pip3" ]]; then
        echo ">> Criando symlink pip3 -> pip3.14 em ${PY_BIN_DIR}..."
        ln -svf pip3.14 "${PY_BIN_DIR}/pip3"
    fi

    echo ">> Python-${PKG_VERSION} construído e instalado em DESTDIR=${DESTDIR}."
}
