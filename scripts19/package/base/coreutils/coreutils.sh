#!/usr/bin/env bash
# coreutils-9.9.sh
#
# Pacote: GNU Coreutils 9.9
#
# Objetivo:
#   - Construir e instalar o coreutils-9.9 no sistema alvo via adm,
#     com destino final em /usr dentro do ADM_ROOTFS.
#
# Integração com adm:
#   - Usa:
#       SRC_DIR  -> diretório com o código-fonte extraído (coreutils-9.9)
#       DESTDIR  -> raiz fake usada para "make install"
#       NUMJOBS  -> número de jobs (opcional)
#   - Respeita TARGET_TRIPLET se definido (cross/nativo).
#
# Notas:
#   - Usa FORCE_UNSAFE_CONFIGURE=1 porque o configure do coreutils
#     não gosta de rodar como root.
#   - --enable-no-install-program=kill,uptime segue o modelo do LFS,
#     já que esses programas normalmente vêm de outros pacotes (procps-ng).

PKG_VERSION="9.9"

SRC_URL="https://ftp.gnu.org/gnu/coreutils/coreutils-${PKG_VERSION}.tar.xz"
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
            TARGET_TRIPLET="$(./build-aux/config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
        fi
    fi

    echo ">> coreutils-${PKG_VERSION} host/target: ${TARGET_TRIPLET}"

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

    # Opcional: se quiser forçar cross, descomente:
    # export CC="${TARGET_TRIPLET}-gcc"

    BUILD_TRIPLET="$(./build-aux/config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
    HOST_TRIPLET="${TARGET_TRIPLET}"

    echo ">> BUILD_TRIPLET = ${BUILD_TRIPLET}"
    echo ">> HOST_TRIPLET  = ${HOST_TRIPLET}"

    # O configure do coreutils reclama se você é root.
    # Esse env ignora esse check de "segurança".
    export FORCE_UNSAFE_CONFIGURE=1

    # ===========================================
    # 3. Diretório de build separado
    # ===========================================

    rm -rf build
    mkdir -v build
    cd       build

    # ===========================================
    # 4. Configure do coreutils
    # ===========================================
    #
    # Opções:
    #   --prefix=/usr
    #   --build/--host
    #   --enable-no-install-program=kill,uptime
    #       -> esses binários virão do procps-ng, tipicamente.
    #
    # Se quiser, você pode ajustar essa lista depois.

    ../configure \
        --prefix=/usr \
        --build="${BUILD_TRIPLET}" \
        --host="${HOST_TRIPLET}" \
        --enable-no-install-program=kill,uptime

    # ===========================================
    # 5. Compilar e instalar em DESTDIR
    # ===========================================

    echo ">> Compilando coreutils-${PKG_VERSION} ..."
    make -j"${NUMJOBS}"

    echo ">> Instalando coreutils-${PKG_VERSION} em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # Ajustes pós-instalação opcionais (ex.: mover programas, doc, etc.)
    # Exemplo: mover chroot pra /usr/sbin se quiser seguir algumas distros:
    # mkdir -pv "${DESTDIR}/usr/sbin"
    # mv -v "${DESTDIR}/usr/bin/chroot" "${DESTDIR}/usr/sbin" || true

    echo ">> coreutils-${PKG_VERSION} construído e instalado em DESTDIR=${DESTDIR}."
}
