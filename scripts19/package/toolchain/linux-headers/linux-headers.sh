#!/usr/bin/env bash
# linux-headers.sh
#
# Instala os Linux API headers (headers do kernel) em /usr/include
# do sistema alvo, no modelo do LFS, mas integrados ao adm:
#
#   - build no SRC_DIR
#   - instala em DESTDIR/usr/include
#   - na instalação real, o adm extrai em ${ADM_ROOTFS}/usr/include
#
# Esses headers serão usados pelo toolchain (glibc/musl, gcc, etc.)
# via CROSS_SYSROOT/ADM_ROOTFS.

PKG_VERSION="6.17.9"

# Tarball oficial do kernel (ajuste o mirror se quiser)
SRC_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"
SRC_MD5=""

pkg_build() {
    # Variáveis fornecidas pelo adm:
    #   SRC_DIR  -> diretório do source já extraído (linux-6.17.9)
    #   DESTDIR  -> raiz fake onde 'make install' é simulado
    #   NUMJOBS  -> opcional, número de jobs
    cd "$SRC_DIR"

    # =========================================
    # 1. Determinar arquitetura para o kernel
    # =========================================
    #
    # O kernel usa ARCH para escolher headers corretos.
    # Se não for passado nada, ele tenta detectar sozinho,
    # mas aqui definimos algo razoável.

    : "${KERNEL_ARCH:=}"

    if [[ -z "$KERNEL_ARCH" ]]; then
        # Baseado em uname -m; mapeia nomes comuns.
        case "$(uname -m)" in
            x86_64|amd64)
                KERNEL_ARCH="x86_64"
                ;;
            i?86)
                KERNEL_ARCH="i386"
                ;;
            aarch64)
                KERNEL_ARCH="arm64"
                ;;
            armv7l|armv6l)
                KERNEL_ARCH="arm"
                ;;
            riscv64)
                KERNEL_ARCH="riscv"
                ;;
            *)
                # fallback: deixa o kernel decidir
                KERNEL_ARCH=""
                ;;
        esac
    fi

    if [[ -n "$KERNEL_ARCH" ]]; then
        echo ">> Linux headers: ARCH=${KERNEL_ARCH}"
        arch_opt=( "ARCH=${KERNEL_ARCH}" )
    else
        echo ">> Linux headers: ARCH não definido explicitamente (kernel irá detectar)."
        arch_opt=()
    fi

    # =========================================
    # 2. Limpar tree e gerar headers
    #    (modelo LFS: mrproper + headers)
    # =========================================

    : "${NUMJOBS:=1}"

    echo ">> make mrproper ..."
    make "${arch_opt[@]}" mrproper

    echo ">> make headers (Linux API headers) ..."
    # Em kernels modernos, 'make headers' gera usr/include com headers limpos.
    make -j"${NUMJOBS}" "${arch_opt[@]}" headers

    # =========================================
    # 3. Limpar arquivos indesejados
    # =========================================
    #
    # Mesmo padrão do LFS:
    #   find usr/include -name '.*' -delete
    #   rm usr/include/Makefile

    echo ">> Limpando arquivos temporários nos headers ..."
    find usr/include -name '.*' -delete
    rm -f usr/include/Makefile

    # =========================================
    # 4. Instalar em DESTDIR/usr/include
    # =========================================
    #
    # O adm depois empacota esse DESTDIR. Na instalação real,
    # isso vira ${ADM_ROOTFS}/usr/include, que é o sysroot que
    # o binutils/gcc/bootstrap vão usar.

    echo ">> Instalando headers em DESTDIR/usr/include ..."
    mkdir -pv "${DESTDIR}/usr"
    cp -rv usr/include "${DESTDIR}/usr"

    echo ">> Linux headers ${PKG_VERSION} preparados em ${DESTDIR}/usr/include"
}
