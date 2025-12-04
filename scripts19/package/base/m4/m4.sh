#!/usr/bin/env bash
# m4-1.4.19.sh
#
# Pacote: GNU M4 1.4.19
#
# Objetivo:
#   - Construir e instalar o m4 no sistema alvo via adm,
#     com destino final em /usr dentro do ADM_ROOTFS.
#
# Integração com adm:
#   - Usa:
#       SRC_DIR  -> diretório com o código-fonte extraído (m4-1.4.19)
#       DESTDIR  -> raiz fake usada para "make install"
#       NUMJOBS  -> número de jobs (opcional)
#   - Respeita TARGET_TRIPLET se definido (cross/nativo).

PKG_VERSION="1.4.19"

SRC_URL="https://ftp.gnu.org/gnu/m4/m4-${PKG_VERSION}.tar.xz"
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
        # Se não foi setado, assumimos build nativo
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            TARGET_TRIPLET="$(./build-aux/config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
        fi
    fi

    echo ">> m4-${PKG_VERSION} alvo/host: ${TARGET_TRIPLET}"

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

    # Podemos deixar o configure escolher o CC padrão, mas se você quiser
    # forçar cross, descomente:
    # export CC="${TARGET_TRIPLET}-gcc"

    BUILD_TRIPLET="$(./build-aux/config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
    HOST_TRIPLET="${TARGET_TRIPLET}"

    echo ">> BUILD_TRIPLET = ${BUILD_TRIPLET}"
    echo ">> HOST_TRIPLET  = ${HOST_TRIPLET}"

    # ===========================================
    # 3. Diretório de build separado (boa prática)
    # ===========================================

    rm -rf build
    mkdir -v build
    cd       build

    # ===========================================
    # 4. Configure do m4
    # ===========================================
    #
    # Opções:
    #   --prefix=/usr       -> instalação padrão do userland
    #   --build/--host      -> bom para cenários cross
    #   --disable-static    -> evitar libs estáticas desnecessárias
    #   --enable-threads=posix  -> garantir suporte a threads posix

    ../configure \
        --prefix=/usr \
        --build="${BUILD_TRIPLET}" \
        --host="${HOST_TRIPLET}" \
        --disable-static \
        --enable-threads=posix

    # ===========================================
    # 5. Compilar e instalar em DESTDIR
    # ===========================================

    echo ">> Compilando m4-${PKG_VERSION} ..."
    make -j"${NUMJOBS}"

    echo ">> Instalando m4-${PKG_VERSION} em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # Se quiser, você pode adicionar aqui pequenas limpezas,
    # como remoção de *.la, mas o m4 normalmente não instala libs extras.

    echo ">> m4-${PKG_VERSION} construído e instalado em DESTDIR=${DESTDIR}."
}
