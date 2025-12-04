#!/usr/bin/env bash
# man-pages-6.16.sh
#
# Pacote: man-pages 6.16
#
# Objetivo:
#   - Instalar as páginas de manual base em /usr/share/man dentro do ADM_ROOTFS,
#     via DESTDIR, usando o sistema de build do adm.
#
# Integração com adm:
#   - Usa:
#       SRC_DIR  -> diretório com o código-fonte extraído (man-pages-6.16)
#       DESTDIR  -> raiz fake onde os arquivos serão colocados
#       NUMJOBS  -> ignorado (não compila nada)
#
# Notas:
#   - O pacote man-pages provê apenas páginas em inglês (man1, man2, man3, ...).
#   - Não há ./configure nem make; é basicamente uma cópia de arquivos.

PKG_VERSION="6.16"

SRC_URL="https://www.kernel.org/pub/linux/docs/man-pages/man-pages-${PKG_VERSION}.tar.xz"
SRC_MD5=""

pkg_build() {
    # Variáveis fornecidas pelo adm:
    #   SRC_DIR, DESTDIR
    cd "$SRC_DIR"

    : "${ADM_ROOTFS:=/}"
    case "$ADM_ROOTFS" in
      /) ;;
      */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
    esac

    echo ">> man-pages-${PKG_VERSION}"
    echo ">> ADM_ROOTFS = ${ADM_ROOTFS}"
    echo ">> DESTDIR    = ${DESTDIR}"

    # Diretório base onde as manpages serão instaladas (no DESTDIR)
    MAN_BASE="${DESTDIR}/usr/share/man"

    # Criar diretório base
    mkdir -pv "${MAN_BASE}"

    # O tarball de man-pages já vem com a estrutura tipo:
    #   man1/, man2/, man3/, man4/, man5/, man7/, man8/
    # Vamos copiar tudo isso para /usr/share/man dentro do DESTDIR.

    echo ">> Instalando páginas de manual em ${MAN_BASE} ..."

    # Copiar diretórios de seções se existirem
    for sec in man1 man2 man3 man4 man5 man7 man8; do
        if [[ -d "$sec" ]]; then
            mkdir -pv "${MAN_BASE}/${sec}"
            # -m 644: arquivos de texto
            install -vm 644 "${sec}"/* "${MAN_BASE}/${sec}/" || true
        fi
    done

    # Algumas versões também possuem man0p, man3p, etc. Podemos copiar tudo
    # o que se parece com "man*".
    #
    # Se quiser ser mais agressivo e garantir tudo, descomente abaixo:
    #
    # for d in man*; do
    #     if [[ -d "$d" ]]; then
    #         mkdir -pv "${MAN_BASE}/${d}"
    #         install -vm 644 "${d}"/* "${MAN_BASE}/${d}/" || true
    #     fi
    # done

    echo ">> man-pages-${PKG_VERSION} instaladas em ${MAN_BASE}."
}
