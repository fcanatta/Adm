#!/usr/bin/env bash
# Build GCC-15.2.0 para o adm
# - Suporta dois perfis via ADM_PROFILE:
#     glibc-final  → GCC final com glibc (LFS 12.4 cap. 8.29)
#     musl-final   → GCC final para alvo *-linux-musl (toolchain musl-native)
#
# Perfis são definidos em /etc/adm.conf, ex:
#   ADM_PROFILE="glibc-final"
# ou
#   ADM_PROFILE="musl-final"

set -euo pipefail

: "${LFS:?Variável LFS não definida}"
: "${LFS_SOURCES_DIR:?Variável LFS_SOURCES_DIR não definida}"

PKG_NAME="gcc"
PKG_VER="15.2.0"
PKG_DIR="${PKG_NAME}-${PKG_VER}"
TARBALL="${PKG_DIR}.tar.xz"
URL="https://ftp.gnu.org/gnu/gcc/${PKG_DIR}/${TARBALL}"

# MD5 do gcc-15.2.0
TARBALL_MD5="b861b092bf1af683c46a8aa2e689a6fd"

SRC_DIR="${LFS_SOURCES_DIR}"
PKG_SRC_DIR="${SRC_DIR}/${PKG_DIR}"

# Se quiser rodar testes: export RUN_GCC_TESTS=1 antes do build
RUN_GCC_TESTS="${RUN_GCC_TESTS:-0}"

log()   { echo "==> [${PKG_NAME}] $*"; }
error() { echo "ERRO [${PKG_NAME}]: $*" >&2; exit 1; }

# -------------------------------------------------------------
#  Seleção de perfil (glibc-final / musl-final)
# -------------------------------------------------------------

select_profile() {
    local profile="${ADM_PROFILE:-glibc-final}"

    case "$profile" in
        glibc-final)
            BUILD_MODE="glibc-final"
            # Final LFS: GCC nativo, glibc, sem --target
            GCC_TARGET=""                            # nativo
            GCC_PREFIX="${ADM_PREFIX:-/usr}"
            GCC_SYSROOT="${ADM_SYSROOT:-/}"
            ;;

        musl-final)
            BUILD_MODE="musl-final"
            # Toolchain musl-native: alvo *-linux-musl
            GCC_TARGET="${ADM_TGT:-$(uname -m)-linux-musl}"
            GCC_PREFIX="${ADM_PREFIX:-/usr}"
            GCC_SYSROOT="${ADM_SYSROOT:-/}"
            ;;

        *)
            error "ADM_PROFILE='$profile' desconhecido. Use 'glibc-final' ou 'musl-final'."
            ;;
    esac

    log "Perfil selecionado: ${profile} (BUILD_MODE=${BUILD_MODE})"
    log "  GCC_PREFIX = ${GCC_PREFIX}"
    log "  GCC_TARGET = ${GCC_TARGET:-<nativo>}"
    log "  GCC_SYSROOT= ${GCC_SYSROOT}"
}

# -------------------------------------------------------------
#  Funções utilitárias (download, checksum, extração)
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

check_md5() {
    local file="${SRC_DIR}/${TARBALL}"

    if ! command -v md5sum >/dev/null 2>&1; then
        log "md5sum não encontrado; NÃO será feita verificação de integridade (use por sua conta e risco)."
        return 0
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

apply_lib64_sed_if_needed() {
    cd "${PKG_SRC_DIR}"
    case "$(uname -m)" in
        x86_64)
            log "Aplicando sed para usar lib em vez de lib64 (t-linux64)..."
            sed -e '/m64=/s/lib64/lib/' \
                -i.orig gcc/config/i386/t-linux64
            ;;
        *)
            log "Arquitetura não é x86_64; ajuste de t-linux64 não é necessário."
            ;;
    esac
}

# -------------------------------------------------------------
#  Configuração de acordo com o perfil
# -------------------------------------------------------------

configure_gcc() {
    cd "${PKG_SRC_DIR}"

    apply_lib64_sed_if_needed

    rm -rf build
    mkdir -v build
    cd build

    log "Configurando GCC-${PKG_VER} (BUILD_MODE=${BUILD_MODE}) ..."

    case "$BUILD_MODE" in
        glibc-final)
            # LFS 12.4 cap. 8.29 – GCC final com glibc
            ../configure \
                --prefix="${GCC_PREFIX}" \
                --build="$(../config.guess)" \
                LD=ld \
                --enable-languages=c,c++ \
                --enable-default-pie \
                --enable-default-ssp \
                --enable-host-pie \
                --disable-multilib \
                --disable-bootstrap \
                --disable-fixincludes \
                --with-system-zlib
            ;;

        musl-final)
            # GCC para alvo *-linux-musl (toolchain musl-native)
            ../configure \
                --prefix="${GCC_PREFIX}" \
                --target="${GCC_TARGET}" \
                --build="$(../config.guess)" \
                --with-sysroot="${GCC_SYSROOT}" \
                --with-native-system-header-dir=/include \
                --enable-languages=c,c++ \
                --disable-multilib \
                --disable-bootstrap \
                --disable-nls \
                --disable-libsanitizer \
                --disable-libquadmath \
                --disable-libitm \
                --disable-libgomp \
                --disable-libmudflap \
                --disable-libssp \
                --with-system-zlib
            ;;

        *)
            error "BUILD_MODE='${BUILD_MODE}' inválido em configure_gcc"
            ;;
    esac
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

    log "Rodando testes do GCC (make -k check) ..."

    ulimit -s -H unlimited || true

    # Pequeno hardening como no livro (remove cpython do plugin.exp)
    sed -e '/cpython/d' -i ../gcc/testsuite/gcc.dg/plugin/plugin.exp || true

    if id -u tester >/dev/null 2>&1; then
        log "Usuário tester encontrado; executando testes como 'tester'."
        chown -R tester .
        su tester -c "PATH=\$PATH make -k check" || true
    else
        log "Usuário tester NÃO encontrado; executando testes como usuário atual."
        make -k check || true
    fi

    if [[ -x ../contrib/test_summary ]]; then
        log "Resumo dos testes (test_summary):"
        ../contrib/test_summary | grep -A7 Summ || true
    fi
}

install_gcc() {
    cd "${PKG_SRC_DIR}/build"

    log "Instalando GCC em ${GCC_PREFIX} ..."
    make install

    # As partes abaixo fazem sentido para ambos modos,
    # mas dependem de onde está o GCC em runtime.
    # No modo musl-final, GCC_TARGET será diferente,
    # mas gcc -dumpmachine ainda funcionará.

    # Ajustar dono dos headers (caso existam nesse caminho)
    if ls /usr/lib/gcc/*linux-gnu/"${PKG_VER}" >/dev/null 2>&1; then
        log "Ajustando proprietário dos headers em /usr/lib/gcc/*linux-gnu/${PKG_VER}/include{,-fixed} ..."
        chown -v -R root:root \
            /usr/lib/gcc/*linux-gnu/"${PKG_VER}"/include{,-fixed} || true
    fi

    # Symlink /usr/lib/cpp -> /usr/bin/cpp (FHS)
    if [[ -x /usr/bin/cpp ]]; then
        log "Criando symlink /usr/lib/cpp -> /usr/bin/cpp ..."
        mkdir -p /usr/lib
        ln -svf /usr/bin/cpp /usr/lib
    fi

    # Manpage cc.1 -> gcc.1
    if [[ -f /usr/share/man/man1/gcc.1 ]]; then
        log "Criando symlink de manpage: cc.1 -> gcc.1 ..."
        ln -svf gcc.1 /usr/share/man/man1/cc.1
    fi

    # Symlink do liblto_plugin.so em /usr/lib/bfd-plugins (se existir)
    if command -v gcc >/dev/null 2>&1; then
        log "Criando symlink do liblto_plugin.so em /usr/lib/bfd-plugins/ ..."
        mkdir -p /usr/lib/bfd-plugins
        ln -sfv ../../libexec/gcc/"$(gcc -dumpmachine)"/"${PKG_VER}"/liblto_plugin.so \
            /usr/lib/bfd-plugins/ || true
    fi

    # Arquivos *gdb.py vão para auto-load (se existirem)
    if ls /usr/lib/*gdb.py >/dev/null 2>&1; then
        log "Movendo *gdb.py para /usr/share/gdb/auto-load/usr/lib ..."
        mkdir -pv /usr/share/gdb/auto-load/usr/lib
        mv -v /usr/lib/*gdb.py /usr/share/gdb/auto-load/usr/lib 2>/dev/null || true
    fi
}

main() {
    log "Iniciando build de ${PKG_NAME}-${PKG_VER}"

    select_profile
    ensure_source_dir
    configure_gcc
    build_gcc
    run_tests_if_enabled
    install_gcc

    log "GCC-${PKG_VER} instalado com sucesso (BUILD_MODE=${BUILD_MODE})."
    log "Se desejar, rode manualmente os sanity-checks do LFS (a.out, dummy.log)."
}

main "$@"
