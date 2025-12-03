# Script de build para musl-1.2.5 no admV2
# - libc alternativa ao glibc
# - instala como libc "nativa" do sistema alvo (prefix=/usr, syslibdir=/lib)
# - aplica 2 patches de segurança em iconv (CVE-2025-26519, EUC-KR + UTF-8 path) 1

PKG_VERSION="1.2.5"

# Tarball oficial do musl 1.2.5
SRC_URL="https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"  # 2
SRC_MD5=""

pkg_build() {
    # Variáveis do admV2:
    #  - SRC_DIR  : fonte do musl já extraído
    #  - DESTDIR  : root fake onde 'make install' cai (adm empacota isso)
    #  - NUMJOBS  : paralelismo (opcional)
    cd "$SRC_DIR"

    # ===========================================================
    # 1. Baixar e aplicar 2 patches de segurança (iconv / CVE-2025-26519)
    #    Usamos os patches backportados pela Bootlin para musl-1.2.5: 3
    #      - 0004-iconv-fix-erroneous-input-validation-in-EUC-KR-decod.patch
    #      - 0005-iconv-harden-UTF-8-output-code-path-against-input-de.patch
    # ===========================================================

    _fetch_patch() {
        local url="$1"
        local out="$2"

        if [[ -f "../$out" ]]; then
            return 0
        fi

        echo ">> Baixando patch $out de $url"
        if command -v curl >/dev/null 2>&1; then
            curl -L -o "../$out" "$url"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "../$out" "$url"
        else
            echo "ERRO: nem curl nem wget disponíveis para baixar $out"
            exit 1
        fi
    }

    local PATCH1="0004-iconv-fix-erroneous-input-validation-in-EUC-KR-decod.patch"
    local PATCH2="0005-iconv-harden-UTF-8-output-code-path-against-input-de.patch"

    local PATCH1_URL="https://toolchains.bootlin.com/downloads/releases/sources/musl-1.2.5/${PATCH1}"
    local PATCH2_URL="https://toolchains.bootlin.com/downloads/releases/sources/musl-1.2.5/${PATCH2}"

    _fetch_patch "$PATCH1_URL" "$PATCH1"
    _fetch_patch "$PATCH2_URL" "$PATCH2"

    echo ">> Aplicando patch de segurança: $PATCH1"
    patch -Np1 -i "../$PATCH1"

    echo ">> Aplicando patch de segurança: $PATCH2"
    patch -Np1 -i "../$PATCH2"

    # ===========================================================
    # 2. Definir TARGET_TRIPLET, ADM_ROOTFS, CROSS_SYSROOT
    # ===========================================================

    : "${TARGET_TRIPLET:=}"

    if [[ -z "$TARGET_TRIPLET" ]]; then
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            TARGET_TRIPLET="$(./configure --help >/dev/null 2>&1; ./config.sub "$(uname -m)-linux" 2>/dev/null || echo unknown-linux-musl)"
        fi
    fi

    echo ">> musl alvo: ${TARGET_TRIPLET}"

    : "${ADM_ROOTFS:=/}"
    case "$ADM_ROOTFS" in
        /) ;;
        */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
    esac

    # Para o GCC/ toolchain, CROSS_SYSROOT é onde estão headers/libs do sistema alvo
    : "${CROSS_SYSROOT:=${ADM_ROOTFS}}"

    echo ">> ADM_ROOTFS    = ${ADM_ROOTFS}"
    echo ">> CROSS_SYSROOT = ${CROSS_SYSROOT}"

    # ===========================================================
    # 3. Toolchain: usar ${TARGET_TRIPLET}-gcc se existir
    # ===========================================================

    : "${NUMJOBS:=1}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    if command -v "${TARGET_TRIPLET}-gcc" >/dev/null 2>&1; then
        export CC="${TARGET_TRIPLET}-gcc"
    else
        # fallback (não é o ideal pra cross, mas deixa o script utilizável)
        export CC="gcc"
    fi

    # ===========================================================
    # 4. Diretório de build e configure
    #    Para sistema nativo musl:
    #      - prefix=/usr        (binaries, headers)
    #      - syslibdir=/lib     (linker dinâmico: /lib/ld-musl-*.so.1) 4
    #      - --host=$TARGET_TRIPLET (cross)
    # ===========================================================

    rm -rf build
    mkdir -v build
    cd       build

    echo ">> Rodando configure do musl..."
    ../configure \
        --prefix=/usr \
        --host="${TARGET_TRIPLET}" \
        --syslibdir=/lib

    # ===========================================================
    # 5. Compilar e instalar no DESTDIR (pacote admV2)
    # ===========================================================

    echo ">> Compilando musl-$(../config.mak 2>/dev/null | grep '^version ' || echo ${PKG_VERSION}) ..."
    make -j"${NUMJOBS}"

    echo ">> Instalando musl em DESTDIR=${DESTDIR} ..."
    make DESTDIR="$DESTDIR" install

    # Depois que o admV2 instalar o pacote, os arquivos vão parar em:
    #   ${ADM_ROOTFS}/usr/include/*
    #   ${ADM_ROOTFS}/usr/lib/libc.so
    #   ${ADM_ROOTFS}/lib/ld-musl-*.so.1
}
