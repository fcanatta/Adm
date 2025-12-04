#!/usr/bin/env bash
# binutils-2.45.1.sh
#
# Binutils "final" para o sistema alvo, integrados ao adm.
#
# Diferença para o binutils-bootstrap:
#   - Aqui o prefix é /usr
#   - É o binutils "definitivo" do sistema (ld, as, objdump, readelf, etc. em /usr/bin)
#   - Deve ser construído quando a libc (glibc/musl) já está instalada no ADM_ROOTFS.
#
# Uso típico:
#   - De DENTRO do chroot (ADM_ROOTFS=/), com GCC nativo configurado
#     ou
#   - Do host, se você tiver um setup de cross mais avançado,
#     mas o alvo principal é o primeiro caso.

PKG_VERSION="2.45.1"

SRC_URL="https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
SRC_MD5=""

pkg_build() {
    # Variáveis fornecidas pelo adm:
    #   SRC_DIR  -> diretório do source (binutils-2.45.1)
    #   DESTDIR  -> raiz fake onde 'make install' cai
    #   NUMJOBS  -> opcional, número de jobs
    cd "$SRC_DIR"

    # =========================================================
    # 1. Determinar TARGET_TRIPLET, ADM_ROOTFS
    # =========================================================

    : "${TARGET_TRIPLET:=}"

    if [[ -z "$TARGET_TRIPLET" ]]; then
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            TARGET_TRIPLET="$(./config.guess 2>/dev/null || echo unknown-unknown-linux-gnu)"
        fi
    fi

    echo ">> Binutils final alvo: ${TARGET_TRIPLET}"

    : "${ADM_ROOTFS:=/}"
    case "$ADM_ROOTFS" in
        /) ;;
        */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
    esac

    echo ">> ADM_ROOTFS = ${ADM_ROOTFS}"

    # =========================================================
    # 2. Verificar se há libc e headers no sysroot
    # =========================================================

    if [[ ! -d "${ADM_ROOTFS}/usr/include" ]]; then
        echo "ERRO: ${ADM_ROOTFS}/usr/include não existe."
        echo "      Instale primeiro linux-headers e a libc (glibc/musl) no ADM_ROOTFS."
        exit 1
    fi

    if [[ ! -f "${ADM_ROOTFS}/usr/include/stdio.h" ]]; then
        echo "ERRO: ${ADM_ROOTFS}/usr/include/stdio.h não existe."
        echo "      A libc do alvo parece não estar instalada corretamente."
        exit 1
    fi

    # =========================================================
    # 3. Determinar BUILD/HOST/TARGET para o configure
    # =========================================================

    BUILD_TRIPLET="$(./config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
    HOST_TRIPLET="${TARGET_TRIPLET}"

    echo ">> BUILD_TRIPLET = ${BUILD_TRIPLET}"
    echo ">> HOST_TRIPLET  = ${HOST_TRIPLET}"

    : "${NUMJOBS:=1}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    # Compilador que constrói o binutils final:
    #   - Se ${TARGET_TRIPLET}-gcc existe (no chroot, deve existir), usamos ele.
    #   - Caso contrário, deixamos o configure descobrir (gcc do ambiente).
    if command -v "${TARGET_TRIPLET}-gcc" >/dev/null 2>&1; then
        export CC="${TARGET_TRIPLET}-gcc"
    fi

    # =========================================================
    # 4. Build em diretório separado
    # =========================================================

    rm -rf build
    mkdir -v build
    cd       build

    # Flags inspiradas no LFS para o binutils final:
    #   --prefix=/usr
    #   --enable-gold
    #   --enable-ld=default
    #   --enable-plugins
    #   --enable-shared
    #   --disable-werror
    #   --with-system-zlib
    cfg_opts=(
        "--prefix=/usr"
        "--build=${BUILD_TRIPLET}"
        "--host=${HOST_TRIPLET}"
        "--target=${TARGET_TRIPLET}"
        "--enable-gold"
        "--enable-ld=default"
        "--enable-plugins"
        "--enable-shared"
        "--disable-werror"
        "--with-system-zlib"
    )

    # Em x86_64, costuma ser desejável --enable-64-bit-bfd
    case "$(uname -m)" in
        x86_64|amd64)
            cfg_opts+=( "--enable-64-bit-bfd" )
            ;;
    esac

    echo ">> Rodando configure com:"
    printf '   %s\n' "${cfg_opts[@]}"

    ../configure "${cfg_opts[@]}"

    echo ">> Compilando binutils-${PKG_VERSION} ..."
    make -j"${NUMJOBS}"

    echo ">> Instalando binutils em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # Pos-instalação simples: remover info duplicada se quiser,
    # mas deixaremos isso para um pacote de "base-system", se necessário.
    echo ">> binutils-${PKG_VERSION} final construído e instalado em DESTDIR=${DESTDIR}."
}
