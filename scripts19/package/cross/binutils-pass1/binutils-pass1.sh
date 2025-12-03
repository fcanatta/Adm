# Script de build para GNU Binutils 2.45.1 (pass1) no admV2
# Focado em uso como binutils "cross/toolchain" inicial.

PKG_VERSION="2.45.1"

# Fonte oficial do GNU (formato .tar.xz)
# Veja lista em ftp.gnu.org/gnu/binutils/ 0
SRC_URL="https://ftp.gnu.org/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"

# Não uso MD5 aqui (o projeto publica SHA256/GPG); deixar vazio faz o admV2 pular a checagem de md5
SRC_MD5=""

pkg_build() {
    # Variáveis fornecidas pelo admV2:
    #   SRC_DIR  -> diretório com o código-fonte já extraído
    #   DESTDIR  -> raiz falsa onde será feito o "make install"
    #   NUMJOBS  -> número de jobs paralelos (setado pelo admV2)
    cd "$SRC_DIR"

    # ======= Configuração de alvo e sysroot ========

    # TARGET_TRIPLET vem normalmente do profile-glibc.sh / profile-musl.sh
    # (ex.: x86_64-pc-linux-gnu, x86_64-linux-musl, etc.)
    : "${TARGET_TRIPLET:=}"

    # Se não tiver TARGET_TRIPLET definido, tenta cair para HOST
    # e, em último caso, usa o triplet "detetado" pelo config.guess.
    if [[ -z "$TARGET_TRIPLET" ]]; then
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            TARGET_TRIPLET="$(./config.guess 2>/dev/null || echo unknown-unknown-linux-gnu)"
        fi
    fi

    echo ">> Binutils pass1 alvo: $TARGET_TRIPLET"

    # SYSROOT alvo para binutils:
    # Por padrão usamos o ADM_ROOTFS (root do sistema que você está montando),
    # mas pode ser sobrescrito com CROSS_SYSROOT se quiser algo diferente.
    : "${ADM_ROOTFS:=/}"
    : "${CROSS_SYSROOT:=$ADM_ROOTFS}"

    # Prefixo dos binutils "pass1" dentro do sistema alvo:
    # NÃO usa /tools nem $LFS – em vez disso, um prefixo neutro /cross-tools.
    # Você pode trocar isso via CROSS_PREFIX se quiser outro layout.
    : "${CROSS_PREFIX:=/cross-tools}"

    echo ">> Binutils pass1 prefix (no alvo): $CROSS_PREFIX"
    echo ">> Binutils pass1 sysroot alvo    : $CROSS_SYSROOT"

    # ======= Flags e paralelismo ========

    : "${NUMJOBS:=1}"

    # Flags de compilação padrão, se não vierem de fora:
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    # ======= Build em diretório separado ========

    mkdir -v build
    cd       build

    # Configuração inspirada no LFS Binutils Pass 1 (mas sem $LFS/$LFS_TGT)
    ../configure \
        --prefix="${CROSS_PREFIX}" \
        --with-sysroot="${CROSS_SYSROOT}" \
        --target="${TARGET_TRIPLET}" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror \
        --enable-new-dtags \
        --enable-default-hash-style=gnu

    # Compila
    make -j"${NUMJOBS}"

    # Passo 1 normalmente não roda test-suite

    # Instala dentro do DESTDIR que o admV2 preparou.
    # O layout final (na hora da instalação do pacote) será:
    #   ${ADM_ROOTFS}${CROSS_PREFIX}/bin/{as,ld,...}
    make DESTDIR="$DESTDIR" install
}
