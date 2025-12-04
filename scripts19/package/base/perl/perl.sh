#!/usr/bin/env bash
# perl-5.42.0.sh
#
# Pacote: Perl 5.42.0
#
# Objetivo:
#   - Construir e instalar o perl-5.42.0 no sistema alvo via adm,
#     com destino final em /usr dentro do ADM_ROOTFS.
#
# Integração com adm:
#   - Usa:
#       SRC_DIR  -> diretório com o código-fonte extraído (perl-5.42.0)
#       DESTDIR  -> raiz fake usada para "make install"
#       NUMJOBS  -> número de jobs (opcional)
#   - TARGET_TRIPLET é usado apenas como informativo / CC opcional.
#
# Observação:
#   - Perl normalmente é construído "nativamente", dentro do chroot.
#     Esse script ainda funciona fora do chroot se o toolchain + libs
#     do ADM_ROOTFS forem compatíveis com o host.

PKG_VERSION="5.42.0"

SRC_URL="https://www.cpan.org/src/5.0/perl-${PKG_VERSION}.tar.gz"
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
            TARGET_TRIPLET="$(./config.guess 2>/dev/null || echo "$(uname -m)-unknown-linux-gnu")"
        fi
    fi

    echo ">> perl-${PKG_VERSION} host/target (informativo): ${TARGET_TRIPLET}"

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

    # Se você quiser FORÇAR o uso do compilador do alvo (em chroot
    # isso vai ser o gcc nativo do sistema), pode descomentar:
    # export CC="${TARGET_TRIPLET}-gcc"

    # ===========================================
    # 3. Rodar Configure do Perl
    # ===========================================
    #
    # Perl não usa ./configure do Autotools, ele tem seu próprio "Configure".
    #
    # Opções recomendadas:
    #   -des                       -> respostas padrão + não interativo
    #   -Dprefix=/usr              -> instala em /usr (usando DESTDIR depois)
    #   -Dvendorprefix=/usr        -> módulos vendor também em /usr
    #   -Dman1dir=/usr/share/man/man1
    #   -Dman3dir=/usr/share/man/man3
    #   -Dpager="/usr/bin/less -isR"
    #   -Duseshrplib               -> compila libperl.so (compartilhada)
    #   -Dusethreads               -> suporte a threads
    #
    # IMPORTANTE:
    #   - NÃO colocar ADM_ROOTFS no prefix.
    #   - A raiz real será DESTDIR durante o "make install".

    echo ">> Rodando Configure do perl-${PKG_VERSION} ..."

    sh Configure -des \
        -Dprefix=/usr \
        -Dvendorprefix=/usr \
        -Dman1dir=/usr/share/man/man1 \
        -Dman3dir=/usr/share/man/man3 \
        -Dpager="/usr/bin/less -isR" \
        -Duseshrplib \
        -Dusethreads

    # ===========================================
    # 4. Compilar e instalar em DESTDIR
    # ===========================================

    echo ">> Compilando perl-${PKG_VERSION} ..."
    make -j"${NUMJOBS}"

    echo ">> Rodando testes básicos do perl (opcional, pode ser demorado)..."
    echo "   (Você pode comentar esta parte se quiser acelerar.)"
    if ! make -k test; then
        echo "AVISO: 'make test' do perl encontrou falhas."
        echo "       Revise se necessário; seguindo adiante com a instalação."
    fi

    echo ">> Instalando perl-${PKG_VERSION} em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # ===========================================
    # 5. Notas pós-instalação
    # ===========================================
    #
    # Perl instalará tipicamente:
    #   - /usr/bin/perl
    #   - /usr/lib/perl5/<versão>/*
    #   - /usr/share/man/man1/perl.1 etc.
    #
    # Qualquer ajuste adicional (links, limpeza, etc.) pode ser feito aqui.

    echo ">> perl-${PKG_VERSION} construído e instalado em DESTDIR=${DESTDIR}."
}
