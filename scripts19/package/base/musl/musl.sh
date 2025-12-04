#!/usr/bin/env bash
# musl-1.2.5.sh
#
# Construção da musl libc 1.2.5 como libc do sistema alvo,
# integrada ao adm e preparada para aplicar patches de segurança.
#
# Instala em /usr (headers) e /lib (loader + libc) dentro do ADM_ROOTFS.
#
# Pré-requisitos no ADM_ROOTFS:
#   - linux-headers instalados em ${ADM_ROOTFS}/usr/include
#   - toolchain alvo funcional (binutils + gcc) para TARGET_TRIPLET
#
# Patches de segurança:
#   - Coloque seus patches reais em:
#       <dir do pacote>/patches/*.patch
#   - Este script aplica TODOS os *.patch dessa pasta em ordem lexicográfica.

PKG_VERSION="1.2.5"

SRC_URL="https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"
SRC_MD5=""

# Diretório base do pacote (onde fica este .sh)
PKG_BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUSL_PATCH_DIR="${MUSL_PATCH_DIR:-${PKG_BASEDIR}/patches}"

pkg_build() {
    # Variáveis fornecidas pelo adm:
    #   SRC_DIR  -> diretório do source da musl já extraído
    #   DESTDIR  -> raiz fake onde 'make install' cai
    #   NUMJOBS  -> opcional, número de jobs
    cd "$SRC_DIR"

    # =====================================================
    # 1. Aplicar patches de segurança (se existirem)
    # =====================================================

    if [[ -d "$MUSL_PATCH_DIR" ]]; then
        echo ">> Aplicando patches de segurança da musl a partir de: ${MUSL_PATCH_DIR}"
        shopt -s nullglob
        patches=( "${MUSL_PATCH_DIR}"/*.patch )
        shopt -u nullglob

        if (( ${#patches[@]} == 0 )); then
            echo "   (Nenhum .patch encontrado em ${MUSL_PATCH_DIR}; seguindo sem patches.)"
        else
            for p in "${patches[@]}"; do
                echo "   * patch -Np1 -i $(basename "$p")"
                patch -Np1 -i "$p"
            done
        fi
    else
        echo ">> Diretório de patches ${MUSL_PATCH_DIR} não existe; seguindo sem patches."
    fi

    # =====================================================
    # 2. TARGET_TRIPLET, ADM_ROOTFS e sanity básico
    # =====================================================

    : "${TARGET_TRIPLET:=}"

    if [[ -z "$TARGET_TRIPLET" ]]; then
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            TARGET_TRIPLET="$(./configure 2>&1 | sed -n 's/^target: //p' | head -n1)"
            [[ -z "$TARGET_TRIPLET" ]] && TARGET_TRIPLET="x86_64-linux-musl"
        fi
    fi

    echo ">> musl alvo: ${TARGET_TRIPLET}"

    : "${ADM_ROOTFS:=/}"
    case "$ADM_ROOTFS" in
        /) ;;
        */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
    esac

    echo ">> ADM_ROOTFS = ${ADM_ROOTFS}"

    if [[ ! -d "${ADM_ROOTFS}/usr/include" ]]; then
        echo "ERRO: ${ADM_ROOTFS}/usr/include não existe."
        echo "      Instale primeiro o pacote linux-headers."
        exit 1
    fi

    # =====================================================
    # 3. CC/CFLAGS e ambiente de build
    # =====================================================

    : "${NUMJOBS:=1}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    # Compilador do alvo (cross ou nativo, dependendo do contexto)
    export CC="${TARGET_TRIPLET}-gcc"

    if ! command -v "$CC" >/dev/null 2>&1; then
        echo "ERRO: Não encontrei compilador alvo '${CC}' no PATH."
        echo "      Instale/configure o GCC alvo (bootstrap/final) primeiro."
        exit 1
    fi

    echo ">> Usando CC=${CC}"

    # =====================================================
    # 4. Configuração da musl
    # =====================================================
    #
    # Notas:
    #   - --prefix=/usr             -> headers /usr/include, libc /lib
    #   - --syslibdir=/lib          -> loader e libc em /lib
    #   - --target=TARGET_TRIPLET   -> triplet musl (ex.: x86_64-linux-musl)
    #
    # Se quiser, adicione flags extras, ex.: --enable-debug, etc.

    rm -rf build
    mkdir -v build
    cd       build

    echo ">> Rodando ./configure da musl..."

    ../configure \
        --prefix=/usr \
        --syslibdir=/lib \
        --target="${TARGET_TRIPLET}"

    # =====================================================
    # 5. Compilar e instalar em DESTDIR
    # =====================================================

    echo ">> Compilando musl-${PKG_VERSION} ..."
    make -j"${NUMJOBS}"

    echo ">> Instalando musl-${PKG_VERSION} em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # -----------------------------------------------------
    # 6. Notas pós-instalação dentro do DESTDIR
    # -----------------------------------------------------
    #
    # A musl instalará normalmente:
    #   - /lib/ld-musl-<arch>.so.1      (loader + libc)
    #   - /lib/libc.so (symlink)
    #   - /usr/include/* (headers)
    #
    # Se quiser ajustes extras (por exemplo, links compatíveis),
    # você pode fazer isso aqui.

    echo ">> musl-${PKG_VERSION} construída e instalada em DESTDIR=${DESTDIR}."
}
