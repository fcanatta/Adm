#!/usr/bin/env bash
# iana-etc-20251120.sh
#
# Pacote: Iana-Etc 20251120
#
# Objetivo:
#   - Instalar os arquivos 'services' e 'protocols' em /etc
#     dentro do ADM_ROOTFS, via DESTDIR.
#
# Integração com adm:
#   - Usa:
#       SRC_DIR  -> diretório com o código-fonte extraído (iana-etc-20251120)
#       DESTDIR  -> raiz fake usada para "make install"
#       NUMJOBS  -> ignorado (não há build)
#   - Não compila nada, apenas copia arquivos.
#
# Observação:
#   - Se você já tiver /etc/services ou /etc/protocols, este script
#     sobrescreve os arquivos no DESTDIR. Se quiser preservar, você
#     pode adaptar para criar .bak ao invés de sobrescrever.

PKG_VERSION="20251120"

# URL segue o padrão da IANA (ajuste se preferir outro mirror)
SRC_URL="https://www.iana.org/assignments/iana-etc/iana-etc-${PKG_VERSION}.tar.gz"
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

    echo ">> Iana-Etc versão ${PKG_VERSION}"
    echo ">> ADM_ROOTFS = ${ADM_ROOTFS}"
    echo ">> DESTDIR    = ${DESTDIR}"

    # Conferir se os arquivos necessários existem no tarball
    if [[ ! -f services ]]; then
        echo "ERRO: arquivo 'services' não encontrado em ${SRC_DIR}."
        exit 1
    fi

    if [[ ! -f protocols ]]; then
        echo "ERRO: arquivo 'protocols' não encontrado em ${SRC_DIR}."
        exit 1
    fi

    # Criar diretório /etc dentro do DESTDIR
    ETC_DIR="${DESTDIR}/etc"
    mkdir -pv "${ETC_DIR}"

    # Opcional: se quiser preservar versões anteriores no DESTDIR, descomente:
    # for f in services protocols; do
    #     if [[ -f "${ETC_DIR}/${f}" ]]; then
    #         mv -v "${ETC_DIR}/${f}" "${ETC_DIR}/${f}.bak-$(date +%s)"
    #     fi
    # done

    # Copiar arquivos para /etc no DESTDIR
    echo ">> Instalando 'services' e 'protocols' em ${ETC_DIR} ..."
    install -vm 644 services   "${ETC_DIR}/services"
    install -vm 644 protocols "${ETC_DIR}/protocols"

    echo ">> Iana-Etc ${PKG_VERSION} instalado em DESTDIR=${DESTDIR}/etc."
}
