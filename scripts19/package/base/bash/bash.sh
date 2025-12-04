#!/usr/bin/env bash
# bash-5.3.sh
#
# Pacote: GNU Bash 5.3
#
# Objetivo:
#   - Construir e instalar o bash-5.3 no sistema alvo via adm,
#     com destino final em /usr (e /bin via symlink se você quiser em outro pacote).
#
# Integração com adm:
#   - Usa:
#       SRC_DIR  -> diretório com o código-fonte extraído (bash-5.3)
#       DESTDIR  -> raiz fake usada para "make install"
#       NUMJOBS  -> número de jobs (opcional)
#   - Respeita TARGET_TRIPLET se definido (cross/nativo).
#
# Notas:
#   - Recomenda-se usar --without-bash-malloc (como LFS e distros fazem).
#   - Docfiles podem ser instalados em /usr/share/doc/bash-5.3 se desejar.

PKG_VERSION="5.3"

SRC_URL="https://ftp.gnu.org/gnu/bash/bash-${PKG_VERSION}.tar.gz"
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
            TARGET_TRIPLET="$(./support/config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
        fi
    fi

    echo ">> bash-${PKG_VERSION} host/target: ${TARGET_TRIPLET}"

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

    # Triplets de build/host (ajuda em cenários cross)
    BUILD_TRIPLET="$(./support/config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
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
    # 4. Configure do bash
    # ===========================================
    #
    # Opções recomendadas:
    #   --prefix=/usr
    #   --build / --host
    #   --without-bash-malloc  -> usa malloc da libc, mais estável
    #   --with-installed-readline -> usar readline de fora (se você tiver),
    #                                ou deixar ele embutir própria readline.
    #
    # Se você ainda não tiver readline como lib separada, pode remover
    # --with-installed-readline, e deixar o bash usar a interna.

    ../configure \
        --prefix=/usr \
        --build="${BUILD_TRIPLET}" \
        --host="${HOST_TRIPLET}" \
        --without-bash-malloc \
        --with-installed-readline

    # ===========================================
    # 5. Compilar e instalar em DESTDIR
    # ===========================================

    echo ">> Compilando bash-${PKG_VERSION} ..."
    make -j"${NUMJOBS}"

    echo ">> Instalando bash-${PKG_VERSION} em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # Opcional: instalar documentação
    # mkdir -pv "${DESTDIR}/usr/share/doc/bash-${PKG_VERSION}"
    # cp -v ../{README,NEWS,AUTHORS,CHANGES} "${DESTDIR}/usr/share/doc/bash-${PKG_VERSION}"

    # Opcional: criar /bin/bash como symlink para /usr/bin/bash.
    # Muitas distros e scripts esperam /bin/bash.
    # Você pode fazer isso aqui ou em um pacote separado de "filesystem".
    #
    # mkdir -pv "${DESTDIR}/bin"
    # ln -svf ../usr/bin/bash "${DESTDIR}/bin/bash"

    echo ">> bash-${PKG_VERSION} construído e instalado em DESTDIR=${DESTDIR}."
}
