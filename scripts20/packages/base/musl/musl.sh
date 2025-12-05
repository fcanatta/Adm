#!/usr/bin/env bash
# Script de construção do pacote: musl 1.2.5
#
# Chamado pelo adm assim:
#   bash musl.sh build <libc>
#
# Variáveis exportadas pelo adm:
#   ADM_CATEGORY      - categoria do pacote (ex: "libc")
#   ADM_PKG_NAME      - nome do pacote (ex: "musl")
#   ADM_LIBC          - libc alvo ("musl")
#   ADM_ROOTFS        - rootfs alvo (ex: /opt/systems/musl-rootfs)
#   ADM_CACHE_SRC     - cache de fontes (ex: /var/cache/adm/sources)
#   ADM_CACHE_PKG     - cache de pacotes binários
#   ADM_BUILD_ROOT    - diretório de build temporário
#   ADM_DESTDIR       - DESTDIR de instalação (vira / dentro do rootfs)
#
# O que este script faz:
#   - baixa musl-1.2.5
#   - aplica patches de segurança (se existirem)
#   - compila e instala em ${ADM_DESTDIR} com prefix=/usr, syslibdir=/lib
#
# Patches de segurança:
#   - Por padrão, procura patches em:
#       /usr/src/adm/patches/musl-1.2.5/*.patch
#   - Você pode sobrescrever com:
#       ADM_MUSL_PATCHDIR=/caminho/dos/patches
#
# Variáveis de ajuste (opcionais):
#   ADM_MUSL_TARBALL_URL   - URL alternativa do tarball
#   ADM_MUSL_BUILD_TRIPLET - triplet de build (default: $(gcc -dumpmachine))
#   ADM_MUSL_TARGET        - alvo (default: igual ao build)
#   ADM_MUSL_PREFIX        - prefix (default: /usr)
#   ADM_MUSL_SYSLIBDIR     - syslibdir (default: /lib)
#   ADM_MUSL_EXTRA_CONFIG  - string com opções extras pro ./configure
#   ADM_MAKE_JOBS          - número de jobs no make (default: nproc ou 1)
#
# O adm usa PKG_VERSION exportada aqui pra registrar a versão do pacote.

set -euo pipefail

# Definir quais libcs esse pacote suporta:
#   - para gcc final: glibc, musl, uclibc-ng
#   - para glibc: apenas glibc
#   - para musl: apenas musl
REQUIRED_LIBCS="glibc musl uclibc-ng"

# Carregar validador de profile
source /usr/src/adm/lib/adm_profile_validate.sh

# Validar profile atual
adm_profile_validate

MUSL_VERSION="1.2.5"
MUSL_NAME="musl-${MUSL_VERSION}"

: "${ADM_CACHE_SRC:=/var/cache/adm/sources}"
: "${ADM_BUILD_ROOT:=/tmp/adm-build-${ADM_CATEGORY:-libc}-${ADM_PKG_NAME:-musl}-${ADM_LIBC:-musl}}"
: "${ADM_DESTDIR:=${ADM_BUILD_ROOT}/destdir}"
: "${ADM_ROOTFS:=/}"

TARBALL="${MUSL_NAME}.tar.gz"
DEFAULT_URL="https://musl.libc.org/releases/${TARBALL}"
MUSL_URL="${ADM_MUSL_TARBALL_URL:-$DEFAULT_URL}"

SRC_ARCHIVE="${ADM_CACHE_SRC}/${TARBALL}"
SRC_DIR="${ADM_BUILD_ROOT}/${MUSL_NAME}"
BUILD_DIR="${SRC_DIR}"   # musl normalmente compila bem in-tree

# Diretório padrão de patches (pode ser sobrescrito)
: "${ADM_MUSL_PATCHDIR:=/usr/src/adm/patches/musl-${MUSL_VERSION}}"

###############################################################################
# FUNÇÕES AUXILIARES
###############################################################################

log()  { printf '[musl] %s\n' "$*"; }
die()  { printf '[musl][ERRO] %s\n' "$*" >&2; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

nproc_safe() {
    if has_cmd nproc; then
        nproc
    else
        echo 1
    fi
}

ensure_tools() {
    local missing=()
    for cmd in tar make cc; do
        has_cmd "$cmd" || missing+=("$cmd")
    done

    # patch só é necessário se houver patches
    if [ -d "$ADM_MUSL_PATCHDIR" ] && ls "$ADM_MUSL_PATCHDIR"/*.patch >/dev/null 2>&1; then
        has_cmd patch || missing+=("patch")
    fi

    # Se não houver tarball em cache, precisamos de curl ou wget
    if [ ! -f "$SRC_ARCHIVE" ]; then
        if ! has_cmd curl && ! has_cmd wget; then
            missing+=("curl/wget")
        fi
    fi

    if ((${#missing[@]} > 0)); then
        die "Ferramentas necessárias ausentes: ${missing[*]}"
    fi
}

fetch_source() {
    mkdir -p "$ADM_CACHE_SRC"

    if [ -f "$SRC_ARCHIVE" ]; then
        log "Tarball já presente em cache: $SRC_ARCHIVE"
        return 0
    fi

    log "Baixando musl ${MUSL_VERSION} de: $MUSL_URL"
    if has_cmd curl; then
        curl -L -o "$SRC_ARCHIVE" "$MUSL_URL"
    elif has_cmd wget; then
        wget -O "$SRC_ARCHIVE" "$MUSL_URL"
    else
        die "Nem curl nem wget disponíveis para download e tarball ausente: $SRC_ARCHIVE"
    fi
}

extract_source() {
    rm -rf "$SRC_DIR"
    mkdir -p "$ADM_BUILD_ROOT"

    log "Extraindo ${SRC_ARCHIVE} em ${ADM_BUILD_ROOT}"
    tar -xf "$SRC_ARCHIVE" -C "$ADM_BUILD_ROOT"

    if [ ! -d "$SRC_DIR" ]; then
        die "Diretório de fonte esperado não encontrado após extração: $SRC_DIR"
    fi
}

apply_patches() {
    if [ ! -d "$ADM_MUSL_PATCHDIR" ]; then
        log "Nenhum diretório de patches encontrado (${ADM_MUSL_PATCHDIR}); pulando aplicação de patches."
        return 0
    fi

    local patch_count=0
    shopt -s nullglob
    local patches=("$ADM_MUSL_PATCHDIR"/*.patch)
    shopt -u nullglob

    if [ "${#patches[@]}" -eq 0 ]; then
        log "Diretório de patches existe, mas não há arquivos .patch; pulando."
        return 0
    fi

    log "Aplicando patches a partir de ${ADM_MUSL_PATCHDIR}:"
    (
        cd "$SRC_DIR"
        for p in "${patches[@]}"; do
            log "  - $(basename "$p")"
            # patch típico de musl geralmente é nível -p1
            patch -Np1 < "$p"
            patch_count=$((patch_count + 1))
        done
    )

    log "Total de patches aplicados: ${patch_count}"
}

###############################################################################
# BUILD / INSTALL
###############################################################################

build_musl() {
    ensure_tools
    fetch_source
    extract_source
    apply_patches

    mkdir -p "$ADM_DESTDIR"

    local build_triplet target_triplet prefix syslibdir extra_cfg jobs
    build_triplet="${ADM_MUSL_BUILD_TRIPLET:-$(cc -dumpmachine 2>/dev/null || echo unknown)}"
    target_triplet="${ADM_MUSL_TARGET:-$build_triplet}"
    prefix="${ADM_MUSL_PREFIX:-/usr}"
    syslibdir="${ADM_MUSL_SYSLIBDIR:-/lib}"
    extra_cfg="${ADM_MUSL_EXTRA_CONFIG:-}"
    jobs="${ADM_MAKE_JOBS:-$(nproc_safe)}"

    log "Triplets:"
    log "  build  = ${build_triplet}"
    log "  target = ${target_triplet}"
    log "Configuração:"
    log "  prefix   = ${prefix}"
    log "  syslibdir= ${syslibdir}"
    log "  rootfs   = ${ADM_ROOTFS}"
    log "  jobs     = ${jobs}"
    [ -n "$extra_cfg" ] && log "  extra cfg= ${extra_cfg}"

    # Apenas aviso – musl não depende tanto quanto glibc disso, mas ajuda
    if [ ! -d "${ADM_ROOTFS%/}/usr/include" ]; then
        log "Aviso: ${ADM_ROOTFS%/}/usr/include não existe. Certifique-se de ter headers do kernel instalados."
    fi

    cd "$BUILD_DIR"

    local cfg_args=(
        "./configure"
        "--prefix=${prefix}"
        "--syslibdir=${syslibdir}"
        "--target=${target_triplet}"
    )

    # Se houver sysroot, avisa (musl não usa --with-sysroot, mas target toolchain sim)
    if [ "${ADM_ROOTFS%/}" != "/" ]; then
        log "Nota: ADM_ROOTFS=${ADM_ROOTFS} (sysroot usado pelo restante do toolchain, não pelo configure do musl)."
    fi

    if [ -n "$extra_cfg" ]; then
        # shellcheck disable=SC2206
        extra_array=( $extra_cfg )
        cfg_args+=("${extra_array[@]}")
    fi

    log "Rodando configure do musl..."
    "${cfg_args[@]}"

    log "Compilando musl (make -j${jobs})..."
    make -j"${jobs}"

    log "Instalando musl em DESTDIR='${ADM_DESTDIR}' (prefix=${prefix}, syslibdir=${syslibdir})..."
    make DESTDIR="${ADM_DESTDIR}" install

    # Informar versão ao adm
    export PKG_VERSION="$MUSL_VERSION"

    log "musl ${MUSL_VERSION} instalado em ${ADM_DESTDIR}${prefix} / ${ADM_DESTDIR}${syslibdir} (para empacotamento pelo adm)."
}

clean_musl() {
    log "Limpando diretório de build: $ADM_BUILD_ROOT"
    rm -rf "$ADM_BUILD_ROOT"
}

###############################################################################
# DISPATCH
###############################################################################

main() {
    local action="${1:-}"

    case "$action" in
        download)
            ensure_tools
            fetch_source
            ;;
        build)
            # $2 é a libc passada pelo adm; aqui esperamos "musl", mas não usamos diretamente
            shift || true
            build_musl
            ;;
        clean)
            clean_musl
            ;;
        *)
            cat <<EOF
Uso: $(basename "$0") <ação> [libc]

Ações suportadas:
  download   - baixa o tarball do musl (${TARBALL}) para o cache
  build      - compila e instala o musl em ADM_DESTDIR (para empacotamento)
  clean      - remove o diretório de build (ADM_BUILD_ROOT)

Fluxo típico com adm:
  adm build ${ADM_CATEGORY:-libc}/${ADM_PKG_NAME:-musl} musl
  adm install ${ADM_CATEGORY:-libc}/${ADM_PKG_NAME:-musl} musl

Variáveis de ajuste (opcionais):
  ADM_MUSL_TARBALL_URL   - URL alternativa do tarball
  ADM_MUSL_BUILD_TRIPLET - triplet de build (default: \$(cc -dumpmachine))
  ADM_MUSL_TARGET        - triplet de target
  ADM_MUSL_PREFIX        - prefix (default: /usr)
  ADM_MUSL_SYSLIBDIR     - syslibdir (default: /lib)
  ADM_MUSL_EXTRA_CONFIG  - opções extras para o configure
  ADM_MUSL_PATCHDIR      - diretório com patches (*.patch) a aplicar
  ADM_MAKE_JOBS          - número de jobs do make (default: nproc ou 1)

EOF
            ;;
    esac
}

main "$@"
