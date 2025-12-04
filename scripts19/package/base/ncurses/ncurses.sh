#!/usr/bin/env bash
# ncurses-6.5-20250809.sh
#
# Pacote: ncurses 6.5 snapshot (2025-08-09)
#
# Objetivo:
#   - Construir e instalar ncurses (wide char) no sistema alvo via adm,
#     com destino final em /usr dentro do ADM_ROOTFS.
#
# Integração com adm:
#   - Usa:
#       SRC_DIR  -> diretório com o código-fonte extraído
#       DESTDIR  -> raiz fake usada para "make install"
#       NUMJOBS  -> número de jobs (opcional)
#   - Respeita TARGET_TRIPLET se definido (cross/nativo).
#
# Notas:
#   - Build wide-character (-lncursesw) apenas.
#   - Cria symlinks libncurses.so -> libncursesw.so e headers compatíveis.
#   - Instala terminfo em /usr/share/terminfo.

PKG_VERSION="6.5-20250809"

# Ajuste a URL conforme onde você pegar o tarball
SRC_URL="https://invisible-mirror.net/archives/ncurses/ncurses-${PKG_VERSION}.tar.gz"
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

    echo ">> ncurses-${PKG_VERSION} host/target: ${TARGET_TRIPLET}"

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

    # Se quiser forçar o compilador:
    # export CC="${TARGET_TRIPLET}-gcc"

    # Determinar BUILD/HOST
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
    # 4. Configure do ncurses (wide-char only)
    # ===========================================
    #
    # Opções principais:
    #   --prefix=/usr
    #   --build/--host
    #   --with-shared              -> libs compartilhadas
    #   --without-debug            -> sem símbolos de debug
    #   --without-ada              -> sem bindings ADA (menos dependências)
    #   --enable-widec             -> compila ncursesw (UTF-8)
    #   --enable-pc-files          -> gera .pc para pkg-config
    #   --with-pkg-config-libdir   -> onde colocar os .pc
    #   --with-termpath, --with-terminfo-dirs, --with-default-terminfo-dir
    #      -> caminhos do terminfo
    #

    ../configure \
        --prefix=/usr \
        --build="${BUILD_TRIPLET}" \
        --host="${HOST_TRIPLET}" \
        --with-shared \
        --without-debug \
        --without-ada \
        --enable-widec \
        --enable-pc-files \
        --with-pkg-config-libdir=/usr/lib/pkgconfig \
        --with-termpath=/usr/share/terminfo \
        --with-default-terminfo-dir=/usr/share/terminfo \
        --with-terminfo-dirs=/usr/share/terminfo

    # ===========================================
    # 5. Compilar e instalar em DESTDIR
    # ===========================================

    echo ">> Compilando ncurses-${PKG_VERSION} ..."
    make -j"${NUMJOBS}"

    echo ">> Instalando ncurses-${PKG_VERSION} em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # ===========================================
    # 6. Ajustes pós-instalação (symlinks compat)
    # ===========================================
    #
    # Como estamos usando widec, as libs ficam como libncursesw.so.
    # Muitas coisas ainda linkam contra -lncurses, então criamos
    # alguns symlinks apropriados.
    #

    LIBDIR="${DESTDIR}/usr/lib"
    INCDIR="${DESTDIR}/usr/include"

    # Symlinks de libncurses.so -> libncursesw.so
    if ls "${LIBDIR}"/libncursesw.so* >/dev/null 2>&1; then
        echo ">> Criando symlinks libncurses* -> libncursesw* ..."
        pushd "${LIBDIR}" >/dev/null

        # libncurses.so -> libncursesw.so
        if [[ -f "libncursesw.so" && ! -e "libncurses.so" ]]; then
            ln -svf libncursesw.so libncurses.so
        fi

        # libtinfo: algumas builds separam, outras não; tentamos criar compat
        if [[ -f "libncursesw.so" && ! -e "libtinfo.so" ]]; then
            ln -svf libncursesw.so libtinfo.so
        fi

        popd >/dev/null
    fi

    # Headers compat: ncurses.h, curses.h, etc.
    if [[ -d "${INCDIR}" ]]; then
        echo ">> Ajustando headers widec em ${INCDIR} ..."
        # Alguns builds instalam ncursesw/curses.h, etc.
        if [[ -d "${INCDIR}/ncursesw" ]]; then
            for hdr in curses.h ncurses.h term.h; do
                if [[ -f "${INCDIR}/ncursesw/${hdr}" && ! -e "${INCDIR}/${hdr}" ]]; then
                    ln -svf "ncursesw/${hdr}" "${INCDIR}/${hdr}"
                fi
            done
        fi
    fi

    echo ">> ncurses-${PKG_VERSION} construído e instalado em DESTDIR=${DESTDIR}."
}
