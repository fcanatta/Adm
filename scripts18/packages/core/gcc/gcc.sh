#!/usr/bin/env bash
# Build GCC-15.2.0 (LFS 12.4, capítulo 8.29) para o adm
set -euo pipefail

# Esperado pelo ambiente do adm (dentro do chroot para build final)
: "${LFS:?Variável LFS não definida}"
: "${LFS_SOURCES_DIR:?Variável LFS_SOURCES_DIR não definida}"

PKG_NAME="gcc"
PKG_VER="15.2.0"
PKG_DIR="${PKG_NAME}-${PKG_VER}"
TARBALL="${PKG_DIR}.tar.xz"
URL="https://ftp.gnu.org/gnu/gcc/${PKG_DIR}/${TARBALL}"
# MD5 oficial do tarball (BLFS r12.4)
TARBALL_MD5="b861b092bf1af683c46a8aa2e689a6fd"

SRC_DIR="${LFS_SOURCES_DIR}"
PKG_SRC_DIR="${SRC_DIR}/${PKG_DIR}"

# Se quiser rodar testes: export RUN_GCC_TESTS=1 antes do build
RUN_GCC_TESTS="${RUN_GCC_TESTS:-0}"

log()   { echo "==> [${PKG_NAME}] $*"; }
error() { echo "ERRO [${PKG_NAME}]: $*" >&2; exit 1; }

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

check_md5() {
    local file="${SRC_DIR}/${TARBALL}"

    if ! command -v md5sum >/dev/null 2>&1; then
        log "md5sum não encontrado; NÃO será feita verificação de integridade (use por sua conta e risco)."
        return
    fi

    if [[ ! -f "${file}" ]]; then
        error "arquivo ${file} não existe para verificar MD5"
    fi

    log "Verificando MD5 de ${file} ..."
    local expected actual
    expected="${TARBALL_MD5}"
    actual="$(md5sum "${file}" | awk '{print $1}')"

    if [[ "${actual}" != "${expected}" ]]; then
        error "MD5 incorreto para ${file}
  Esperado: ${expected}
  Obtido..: ${actual}
Apague o tarball e tente novamente."
    fi

    log "MD5 OK (${actual})"
}

ensure_source_dir() {
    if [[ -d "${PKG_SRC_DIR}" ]]; then
        log "Diretório de fontes já existe: ${PKG_SRC_DIR}"
        return 0
    fi

    fetch_tarball
    check_md5

    log "Extraindo ${TARBALL} em ${SRC_DIR} ..."
    tar -xf "${SRC_DIR}/${TARBALL}" -C "${SRC_DIR}"

    if [[ ! -d "${PKG_SRC_DIR}" ]]; then
        error "diretório ${PKG_SRC_DIR} não encontrado após extração"
    fi
}

apply_lfs_sed() {
    # Passo do LFS: ajustar lib64 -> lib em x86_64
    # case $(uname -m) in x86_64) sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;;
    case "$(uname -m)" in
        x86_64)
            log "Aplicando sed para usar lib em vez de lib64 (t-linux64)..."
            sed -e '/m64=/s/lib64/lib/' \
                -i.orig gcc/config/i386/t-linux64
            ;;
        *)
            log "Arquitetura não é x86_64; sed de t-linux64 não é necessário."
            ;;
    esac
}

configure_gcc() {
    cd "${PKG_SRC_DIR}"

    apply_lfs_sed

    # Diretório de build dedicado
    rm -rf build
    mkdir -v build
    cd build

    log "Configurando GCC-${PKG_VER} (LFS 12.4, cap. 8.29)..."
    ../configure --prefix=/usr            \
                 LD=ld                    \
                 --enable-languages=c,c++ \
                 --enable-default-pie     \
                 --enable-default-ssp     \
                 --enable-host-pie        \
                 --disable-multilib       \
                 --disable-bootstrap      \
                 --disable-fixincludes    \
                 --with-system-zlib
}

build_gcc() {
    cd "${PKG_SRC_DIR}/build"
    log "Compilando GCC ..."
    make
}

run_tests_if_enabled() {
    cd "${PKG_SRC_DIR}/build"

    if [[ "${RUN_GCC_TESTS}" != "1" ]]; then
        log "RUN_GCC_TESTS!=1; testes do GCC serão **pulados**."
        return 0
    fi

    log "Rodando testes do GCC (make -k check) como usuário 'tester', se existir..."

    # Definir limite de stack como no livro
    ulimit -s -H unlimited || true

    # Ajuste do plugin de testes (cpython) como no LFS
    sed -e '/cpython/d' -i ../gcc/testsuite/gcc.dg/plugin/plugin.exp || true

    # Se existir usuário 'tester', usa; senão roda como usuário atual mesmo
    local test_user="tester"
    if id -u tester >/dev/null 2>&1; then
        log "Usuário tester encontrado; executando testes como 'tester'."
        chown -R tester .
        su tester -c "PATH=\$PATH make -k check" || true
    else
        log "Usuário tester NÃO encontrado; executando testes como usuário atual."
        make -k check || true
    fi

    # Sumário (apenas ecoa no log; não falha se der erro)
    if [[ -x ../contrib/test_summary ]]; then
        log "Resumo dos testes (test_summary):"
        ../contrib/test_summary | grep -A7 Summ || true
    fi
}

install_gcc() {
    cd "${PKG_SRC_DIR}/build"

    log "Instalando GCC em /usr ..."
    make install

    # Ajustar dono dos headers, como no livro
    log "Ajustando proprietário dos headers em /usr/lib/gcc/*linux-gnu/${PKG_VER}/include{,-fixed} ..."
    chown -v -R root:root \
        /usr/lib/gcc/*linux-gnu/"${PKG_VER}"/include{,-fixed} || true

    # Symlink histórico para cpp (FHS)
    log "Criando symlink /usr/lib/cpp -> /usr/bin/cpp ..."
    ln -svf /usr/bin/cpp /usr/lib || true

    # Symlink da man page cc.1
    log "Criando symlink de manpage: cc.1 -> gcc.1 ..."
    ln -svf gcc.1 /usr/share/man/man1/cc.1 || true

    # Symlink do liblto_plugin.so para binutils (bfd-plugins)
    log "Criando symlink do liblto_plugin.so em /usr/lib/bfd-plugins/ ..."
    mkdir -p /usr/lib/bfd-plugins
    ln -sfv ../../libexec/gcc/"$(gcc -dumpmachine)"/"${PKG_VER}"/liblto_plugin.so \
        /usr/lib/bfd-plugins/ || true

    # Arquivos *gdb.py vão para auto-load
    log "Movendo *gdb.py para /usr/share/gdb/auto-load/usr/lib ..."
    mkdir -pv /usr/share/gdb/auto-load/usr/lib
    mv -v /usr/lib/*gdb.py /usr/share/gdb/auto-load/usr/lib 2>/dev/null || true
}

main() {
    log "Iniciando build de ${PKG_NAME}-${PKG_VER} (final, LFS 12.4 cap. 8.29)"
    log "LFS             = ${LFS}"
    log "LFS_SOURCES_DIR = ${LFS_SOURCES_DIR}"

    ensure_source_dir
    configure_gcc
    build_gcc
    run_tests_if_enabled
    install_gcc

    log "GCC-${PKG_VER} instalado com sucesso."
    log "Se desejar, rode manualmente os sanity-checks do LFS (a.out, dummy.log)."
}

main "$@"
