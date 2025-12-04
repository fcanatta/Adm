#!/usr/bin/env bash
# pkgconf-2.5.1.sh
#
# Pacote: pkgconf 2.5.1
#
# Objetivo:
#   - Construir e instalar o pkgconf-2.5.1 no sistema alvo via adm,
#     com destino final em /usr dentro do ADM_ROOTFS.
#
# Integração com adm:
#   - Usa:
#       SRC_DIR  -> diretório com o código-fonte extraído (pkgconf-2.5.1)
#       DESTDIR  -> raiz fake usada para "make/meson install"
#       NUMJOBS  -> número de jobs (opcional)
#   - Respeita TARGET_TRIPLET se definido (informativo).
#
# Notas:
#   - O pkgconf 2.x usa Meson como sistema de build.
#   - É necessário ter 'meson' e 'ninja' disponíveis no PATH.

PKG_VERSION="2.5.1"

SRC_URL="https://distfiles.dereferenced.org/pkgconf/pkgconf-${PKG_VERSION}.tar.xz"
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
            TARGET_TRIPLET="$(uname -m)-unknown-linux-gnu"
        fi
    fi

    echo ">> pkgconf-${PKG_VERSION} host/target (informativo): ${TARGET_TRIPLET}"

    : "${ADM_ROOTFS:=/}"
    case "$ADM_ROOTFS" in
        /) ;;
        */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
    esac
    echo ">> ADM_ROOTFS = ${ADM_ROOTFS}"

    # ===========================================
    # 2. Checar Meson/Ninja
    # ===========================================

    if ! command -v meson >/dev/null 2>&1; then
        echo "ERRO: 'meson' não encontrado no PATH."
        echo "      Instale primeiro meson (e ninja) como parte dos build-tools."
        exit 1
    fi

    if ! command -v ninja >/dev/null 2>&1; then
        echo "ERRO: 'ninja' não encontrado no PATH."
        echo "      Instale primeiro ninja como parte dos build-tools."
        exit 1
    fi

    echo ">> meson encontrado em: $(command -v meson)"
    echo ">> ninja encontrado em: $(command -v ninja)"

    # ===========================================
    # 3. Flags padrão e ambiente
    # ===========================================

    : "${NUMJOBS:=1}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    export CFLAGS
    export CXXFLAGS

    # Se quiser forçar um CC específico:
    # export CC="${TARGET_TRIPLET}-gcc"

    # ===========================================
    # 4. Diretório de build com Meson
    # ===========================================

    rm -rf build
    meson setup build \
        --prefix=/usr \
        --buildtype=release \
        -Dtests=false

    # ===========================================
    # 5. Compilação
    # ===========================================

    echo ">> Compilando pkgconf-${PKG_VERSION} ..."
    meson compile -C build -j"${NUMJOBS}"

    # ===========================================
    # 6. Instalação em DESTDIR
    # ===========================================

    echo ">> Instalando pkgconf-${PKG_VERSION} em DESTDIR=${DESTDIR} ..."
    meson install -C build --destdir "${DESTDIR}"

    # Normalmente instala:
    #   /usr/bin/pkgconf
    #   /usr/bin/pkg-config (wrapper)
    #   /usr/share/pkgconfig/*.pc (do próprio pkgconf)
    #
    # Se por algum motivo pkg-config não existir, podemos criar symlink.

    BIN_DIR="${DESTDIR}/usr/bin"
    if [[ -x "${BIN_DIR}/pkgconf" && ! -e "${BIN_DIR}/pkg-config" ]]; then
        echo ">> Criando symlink pkg-config -> pkgconf em ${BIN_DIR}..."
        ln -svf pkgconf "${BIN_DIR}/pkg-config"
    fi

    echo ">> pkgconf-${PKG_VERSION} construído e instalado em DESTDIR=${DESTDIR}."
}
