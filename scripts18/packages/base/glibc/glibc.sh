#!/usr/bin/env bash
# Build Glibc-2.42 para o adm
# - Usa ADM_PROFILE para decidir o modo:
#     glibc-final → glibc como libc principal do sistema (modo LFS final)
#
# Requisitos (de upstream / distros):
#   - GCC >= 12.1
#   - Binutils >= 2.39
#
# Fonte: ftp.gnu.org (glibc-2.42.tar.xz)
# SHA256: d1775e32e4628e64ef930f435b67bb63af7599acb6be2b335b9f19f16509f17f
#
# Instruções baseadas em:
#   - LFS/CLFS-ng Glibc-2.42 (configure, sed, ldd, locales, etc.)
#
# Perfis:
#   - ADM_PROFILE="glibc-final" (recomendado em /etc/adm.conf)

set -euo pipefail

: "${LFS:?Variável LFS não definida}"
: "${LFS_SOURCES_DIR:?Variável LFS_SOURCES_DIR não definida}"

PKG_NAME="glibc"
PKG_VER="2.42"
PKG_DIR="${PKG_NAME}-${PKG_VER}"
TARBALL="${PKG_DIR}.tar.xz"
URL="https://ftp.gnu.org/gnu/libc/${TARBALL}"

# SHA256 oficial (glibc-2.42.tar.xz)
TARBALL_SHA256="d1775e32e4628e64ef930f435b67bb63af7599acb6be2b335b9f19f16509f17f"

SRC_DIR="${LFS_SOURCES_DIR}"
PKG_SRC_DIR="${SRC_DIR}/${PKG_DIR}"

log()   { echo "==> [${PKG_NAME}] $*"; }
error() { echo "ERRO [${PKG_NAME}]: $*" >&2; exit 1; }

# Controle de testes e locales via env:
# - RUN_GLIBC_TESTS=1  → roda make check
# - GLIBC_LOCALES=none|minimal|all (default: minimal)
RUN_GLIBC_TESTS="${RUN_GLIBC_TESTS:-0}"
GLIBC_LOCALES="${GLIBC_LOCALES:-minimal}"

# -------------------------------------------------------------
#  Seleção de perfil (aqui só aceitamos glibc-final)
# -------------------------------------------------------------

select_profile() {
    local profile="${ADM_PROFILE:-glibc-final}"

    case "$profile" in
        glibc-final)
            BUILD_MODE="glibc-final"
            # glibc final sempre instala em /usr (como no LFS)
            GLIBC_PREFIX="/usr"
            ;;

        *)
            error "ADM_PROFILE='$profile' inválido para glibc.
Use ADM_PROFILE='glibc-final' em /etc/adm.conf para construir a glibc final."
            ;;
    esac

    log "Perfil selecionado: ${profile} (BUILD_MODE=${BUILD_MODE})"
    log "  GLIBC_PREFIX = ${GLIBC_PREFIX}"
}

# -------------------------------------------------------------
#  Download, checksum, extração
# -------------------------------------------------------------

fetch_tarball() {
    mkdir -p "${SRC_DIR}"

    local dst="${SRC_DIR}/${TARBALL}"
    if [[ -f "${dst}" ]]; then
        log "Tarball já existe: ${dst}"
        return 0
    fi

    log "Baixando ${TARBALL} de ${URL} ..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL -o "${dst}" "${URL}" \
            || error "falha ao baixar ${URL} com curl"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${dst}" "${URL}" \
            || error "falha ao baixar ${URL} com wget"
    else
        error "nem curl nem wget encontrados para baixar o tarball"
    fi
}

check_sha256() {
    local file="${SRC_DIR}/${TARBALL}"

    if ! command -v sha256sum >/dev/null 2>&1; then
        log "sha256sum não encontrado; NÃO será feita verificação de integridade (use por sua conta e risco)."
        return 0
    fi

    if [[ ! -f "${file}" ]]; then
        error "arquivo ${file} não existe para verificar SHA256"
    fi

    log "Verificando SHA256 de ${file} ..."
    local expected actual
    expected="${TARBALL_SHA256}"
    actual="$(sha256sum "${file}" | awk '{print $1}')"

    if [[ "${actual}" != "${expected}" ]]; then
        error "SHA256 incorreto para ${file}
  Esperado: ${expected}
  Obtido..: ${actual}
Apague o tarball e tente novamente."
    fi

    log "SHA256 OK (${actual})"
}

ensure_source_dir() {
    if [[ -d "${PKG_SRC_DIR}" ]]; then
        log "Diretório de fontes já existe: ${PKG_SRC_DIR}"
        return 0
    fi

    fetch_tarball
    check_sha256

    log "Extraindo ${TARBALL} em ${SRC_DIR} ..."
    tar -xf "${SRC_DIR}/${TARBALL}" -C "${SRC_DIR}"

    if [[ ! -d "${PKG_SRC_DIR}" ]]; then
        error "diretório ${PKG_SRC_DIR} não encontrado após extração"
    fi
}

# -------------------------------------------------------------
#  Ajustes pré-configure (sed etc.)
# -------------------------------------------------------------

apply_pre_config_fixes() {
    cd "${PKG_SRC_DIR}"

    log "Aplicando ajustes em stdlib/abort.c (segundo CLFS-ng/LFS) ..."
    sed -e '/unistd.h/i #include <string.h>' \
        -e '/libc_rwlock_init/c\
  __libc_rwlock_define_initialized (, reset_lock);\
  memcpy (&lock, &reset_lock, sizeof (lock));' \
        -i stdlib/abort.c

    # Aviso do LFS: touch /etc/ld.so.conf para evitar warning no make install
    log "Garantindo /etc/ld.so.conf para evitar warning da glibc ..."
    touch /etc/ld.so.conf
}

# -------------------------------------------------------------
#  Configuração de acordo com o perfil
# -------------------------------------------------------------

configure_glibc() {
    cd "${PKG_SRC_DIR}"

    rm -rf build
    mkdir -v build
    cd build

    log "Configurando Glibc-${PKG_VER} (BUILD_MODE=${BUILD_MODE}) ..."

    # Config de acordo com LFS/CLFS-ng 2.42:
    #   --prefix=/usr
    #   --disable-werror
    #   --disable-nscd
    #   libc_cv_slibdir=/usr/lib
    #   --enable-stack-protector=strong
    #   --enable-kernel=6.16.1
    #
    # Nota: --enable-kernel define o kernel mínimo suportado;
    # aqui seguimos o valor recomendado nesse perfil.
    ../configure \
        --prefix="${GLIBC_PREFIX}"       \
        --disable-werror                 \
        --disable-nscd                   \
        libc_cv_slibdir=/usr/lib         \
        --enable-stack-protector=strong  \
        --enable-kernel=6.16.1
}

build_glibc() {
    cd "${PKG_SRC_DIR}/build"
    log "Compilando Glibc ..."
    make
}

run_tests_if_enabled() {
    cd "${PKG_SRC_DIR}/build"

    if [[ "${RUN_GLIBC_TESTS}" != "1" ]]; then
        log "RUN_GLIBC_TESTS!=1; testes da Glibc (make check) serão **pulados**."
        log "ATENÇÃO: LFS considera os testes da Glibc críticos. Habilite-os exportando RUN_GLIBC_TESTS=1."
        return 0
    fi

    log "Rodando testes da Glibc (make check) ..."
    # Alguns testes falham ocasionalmente; aqui não abortamos o build inteiro.
    make check || log "make check retornou falhas; verifique os logs em ${PKG_SRC_DIR}/build"
}

install_glibc() {
    cd "${PKG_SRC_DIR}/build"

    # LFS recomenda desativar um sanity-check antigo antes do make install:
    log "Desativando sanity-check antigo em test-installation ..."
    sed '/test-installation/s@$(PERL)@echo not running@' -i ../Makefile

    log "Instalando Glibc em ${GLIBC_PREFIX} ..."
    make install

    # Ajuste do ldd: remover /usr hardcoded em RTLDLIST
    if [[ -x /usr/bin/ldd ]]; then
        log "Ajustando /usr/bin/ldd (RTLDLIST) ..."
        sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd
    fi
}

install_locales() {
    cd "${PKG_SRC_DIR}/build"

    case "${GLIBC_LOCALES}" in
        none)
            log "GLIBC_LOCALES=none; nenhuma locale adicional será instalada."
            ;;

        minimal)
            log "Instalando conjunto mínimo de locales recomendadas pelo LFS ..."
            # Esses comandos são executados no sistema já com glibc instalada
            localedef -i C      -f UTF-8 C.UTF-8 || true
            localedef -i cs_CZ  -f UTF-8 cs_CZ.UTF-8 || true
            localedef -i de_DE  -f ISO-8859-1 de_DE || true
            localedef -i de_DE  -f UTF-8 de_DE.UTF-8 || true
            localedef -i de_DE@euro -f ISO-8859-15 de_DE@euro || true
            localedef -i el_GR  -f ISO-8859-7 el_GR || true
            localedef -i en_GB  -f ISO-8859-1 en_GB || true
            localedef -i en_GB  -f UTF-8 en_GB.UTF-8 || true
            localedef -i en_HK  -f ISO-8859-1 en_HK || true
            localedef -i en_PH  -f ISO-8859-1 en_PH || true
            localedef -i en_US  -f ISO-8859-1 en_US || true
            localedef -i en_US  -f UTF-8 en_US.UTF-8 || true
            localedef -i es_ES  -f ISO-8859-15 es_ES@euro || true
            localedef -i es_MX  -f ISO-8859-1 es_MX || true
            localedef -i fa_IR  -f UTF-8 fa_IR || true
            localedef -i fr_FR  -f ISO-8859-1 fr_FR || true
            localedef -i fr_FR@euro -f ISO-8859-15 fr_FR@euro || true
            localedef -i fr_FR  -f UTF-8 fr_FR.UTF-8 || true
            localedef -i is_IS  -f ISO-8859-1 is_IS || true
            localedef -i is_IS  -f UTF-8 is_IS.UTF-8 || true
            localedef -i it_IT  -f ISO-8859-1 it_IT || true
            localedef -i it_IT  -f ISO-8859-15 it_IT@euro || true
            localedef -i it_IT  -f UTF-8 it_IT.UTF-8 || true
            localedef -i ja_JP  -f EUC-JP ja_JP || true
            localedef -i ja_JP  -f UTF-8 ja_JP.UTF-8 || true
            localedef -i nl_NL@euro -f ISO-8859-15 nl_NL@euro || true
            localedef -i ru_RU  -f KOI8-R ru_RU.KOI8-R || true
            localedef -i ru_RU  -f UTF-8 ru_RU.UTF-8 || true
            localedef -i se_NO  -f UTF-8 se_NO || true
            localedef -i ta_IN  -f UTF-8 ta_IN || true
            localedef -i tr_TR  -f UTF-8 tr_TR || true
            localedef -i zh_CN  -f GB18030 zh_CN.GB18030 || true
            localedef -i zh_HK  -f BIG5-HKSCS zh_HK.BIG5-HKSCS || true
            localedef -i zh_TW  -f UTF-8 zh_TW.UTF-8 || true
            ;;

        all)
            log "Instalando todas as locales suportadas (make localedata/install-locales) ..."
            make localedata/install-locales || true
            ;;

        *)
            log "GLIBC_LOCALES='${GLIBC_LOCALES}' não reconhecido; usando 'minimal'."
            GLIBC_LOCALES="minimal"
            install_locales
            ;;
    esac
}

main() {
    log "Iniciando build de ${PKG_NAME}-${PKG_VER}"

    select_profile
    ensure_source_dir
    apply_pre_config_fixes
    configure_glibc
    build_glibc
    run_tests_if_enabled
    install_glibc
    install_locales

    log "Glibc-${PKG_VER} instalada com sucesso (BUILD_MODE=${BUILD_MODE})."
    log "Recomenda-se reboot após atualizar a glibc em um sistema em uso."
}

main "$@"
