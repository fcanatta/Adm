#!/usr/bin/env bash
# glibc-2.42.sh
#
# Glibc "final" para o sistema alvo, integrada ao adm.
# Instala em /usr e /lib dentro do ADM_ROOTFS (via DESTDIR).
#
# Pré-requisitos no ADM_ROOTFS:
#   - Linux headers em /usr/include (pacote linux-headers)
#   - toolchain bootstrap funcionando:
#       binutils-bootstrap
#       gcc-bootstrap (com --with-sysroot=${ADM_ROOTFS})
#
# Observação:
#   Este script constrói a libc; geração de locais (locales)
#   e configuração de /etc/nsswitch.conf, /etc/ld.so.conf etc.
#   podem ser feitos em pacotes separados de "base-system".

PKG_VERSION="2.42"

SRC_URL="https://ftp.gnu.org/gnu/glibc/glibc-${PKG_VERSION}.tar.xz"
SRC_MD5=""

pkg_build() {
    # Variáveis fornecidas pelo adm:
    #   SRC_DIR  -> diretório do source da glibc já extraído
    #   DESTDIR  -> raiz fake para 'make install'
    #   NUMJOBS  -> paralelismo (opcional)
    cd "$SRC_DIR"

    # ============================================================== 
    # 1. Segurança: glibc só faz sentido no PROFILE=glibc
    # ==============================================================

    if [[ "${PROFILE:-glibc}" != "glibc" ]]; then
        echo "ERRO: Este pacote glibc-2.42 deve ser usado apenas no PROFILE=glibc."
        echo "      PROFILE atual: ${PROFILE:-<não definido>}"
        exit 1
    fi

    # ============================================================== 
    # 2. TARGET_TRIPLET, ADM_ROOTFS, CROSS_SYSROOT
    # ==============================================================

    : "${TARGET_TRIPLET:=}"

    if [[ -z "$TARGET_TRIPLET" ]]; then
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            TARGET_TRIPLET="$(./scripts/config.guess 2>/dev/null || echo unknown-unknown-linux-gnu)"
        fi
    fi

    echo ">> Glibc final alvo: ${TARGET_TRIPLET}"

    : "${ADM_ROOTFS:=/}"
    case "$ADM_ROOTFS" in
        /) ;;
        */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
    esac

    : "${CROSS_SYSROOT:=${ADM_ROOTFS}}"

    echo ">> ADM_ROOTFS    = ${ADM_ROOTFS}"
    echo ">> CROSS_SYSROOT = ${CROSS_SYSROOT}"

    # ============================================================== 
    # 3. Verificar se os Linux headers existem no sysroot
    # ==============================================================

    if [[ ! -d "${CROSS_SYSROOT}/usr/include" ]]; then
        echo "ERRO: ${CROSS_SYSROOT}/usr/include não existe."
        echo "      Instale primeiro o pacote linux-headers."
        exit 1
    fi

    if [[ ! -f "${CROSS_SYSROOT}/usr/include/linux/version.h" ]]; then
        echo "ERRO: linux/version.h não encontrado em ${CROSS_SYSROOT}/usr/include/linux."
        echo "      Verifique a instalação do pacote linux-headers."
        exit 1
    fi

    # ============================================================== 
    # 4. Flags, build dir e configure
    # ==============================================================

    : "${NUMJOBS:=1}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    # Compilador do alvo (fornecido pelo gcc-bootstrap ou gcc final)
    export CC="${TARGET_TRIPLET}-gcc"
    export CXX="${TARGET_TRIPLET}-g++"

    # Diretório de build separado, como recomendado pelo manual da glibc
    rm -rf build
    mkdir -v build
    cd       build

    # Para sistemas x86_64 modernos, é comum:
    #   --enable-kernel=4.19
    #   libc_cv_slibdir=/usr/lib
    # O dynamic linker (/lib/ld-linux-*.so.2) será criado pela glibc corretamente.
    BUILD_TRIPLET="$("$SRC_DIR"/scripts/config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"

    echo ">> BUILD_TRIPLET = ${BUILD_TRIPLET}"

    # libc_cv_slibdir controla onde as libs "shared" vivem (/usr/lib é o padrão LFS)
    export libc_cv_slibdir="/usr/lib"

    "$SRC_DIR"/configure \
        --prefix=/usr \
        --host="${TARGET_TRIPLET}" \
        --build="${BUILD_TRIPLET}" \
        --enable-kernel=4.19 \
        --with-headers="${CROSS_SYSROOT}/usr/include" \
        --enable-stack-protector=strong \
        --disable-werror

    # ============================================================== 
    # 5. Build e instalação
    # ==============================================================

    make -j"${NUMJOBS}"

    # Testes da glibc são pesados; normalmente você executa mais tarde
    # dentro do chroot. Aqui, por padrão, pulamos.
    # Se quiser rodar testes aqui, adicione:
    #   make check

    echo ">> Instalando glibc em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # ============================================================== 
    # 6. Ajustes pós-installation dentro do DESTDIR
    # ==============================================================

    # /etc/ld.so.conf normalmente é responsabilidade de um pacote "base-system",
    # mas podemos garantir que o diretório exista.
    mkdir -pv "${DESTDIR}/etc"

    # Opcionalmente, poderíamos criar um ld.so.conf mínimo:
    # if [[ ! -f "${DESTDIR}/etc/ld.so.conf" ]]; then
    #   cat > "${DESTDIR}/etc/ld.so.conf" << 'EOF'
    # /usr/local/lib
    # /usr/lib
    # EOF
    # fi

    # Diretórios cache do nscd, se o usuário decidir usar nscd depois
    mkdir -pv "${DESTDIR}/var/cache/nscd"

    echo ">> glibc-${PKG_VERSION} construída e instalada em DESTDIR=${DESTDIR}."
}
