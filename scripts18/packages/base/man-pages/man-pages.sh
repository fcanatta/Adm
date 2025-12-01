#!/usr/bin/env bash
# Build man-pages-6.16 para o adm
#
# Baseado no LFS (seção Man-pages-6.10), adaptado:
#   - Remove man3/crypt* (Libxcrypt fornece páginas melhores)
#   - make prefix=/usr install
#
# Suporta perfis:
#   ADM_PROFILE=glibc-final
#   ADM_PROFILE=musl-final
#
# Instala em /usr/share/man dentro do chroot.

set -euo pipefail

PKG_NAME="man-pages"
PKG_VERSION="6.16"
PKG_TARBALL="${PKG_NAME}-${PKG_VERSION}.tar.xz"
PKG_BASE_URL="https://www.kernel.org/pub/linux/docs/man-pages"
PKG_URL="${PKG_BASE_URL}/${PKG_TARBALL}"

# SHA256 oficial do man-pages-6.16.tar.xz (sha256sums.asc em kernel.org)
PKG_SHA256="8e247abd75cd80809cfe08696c81b8c70690583b045749484b242fb43631d7a3"

: "${LFS_SOURCES_DIR:?LFS_SOURCES_DIR não definido}"

log() {
    printf '[%s] %s\n' "${PKG_NAME}" "$*" >&2
}

error() {
    printf '[%s:ERRO] %s\n' "${PKG_NAME}" "$*" >&2
    exit 1
}

# -------------------------------------------------------------
# Seleção de perfil (glibc-final / musl-final)
# -------------------------------------------------------------

select_profile() {
    local profile="${ADM_PROFILE:-}"

    case "${profile}" in
        glibc-final|musl-final)
            PREFIX="/usr"
            ;;
        *)
            error "ADM_PROFILE='${profile}' não suportado para ${PKG_NAME}.
Use glibc-final ou musl-final dentro do chroot apropriado."
            ;;
    esac

    log "Perfil selecionado: ${profile}"
    log "  PREFIX = ${PREFIX}"
}

# -------------------------------------------------------------
# Download, checksum, extração
# -------------------------------------------------------------

fetch_tarball() {
    cd "${LFS_SOURCES_DIR}"

    if [[ -f "${PKG_TARBALL}" ]]; then
        log "Tarball já existe: ${PKG_TARBALL}"
        return
    fi

    log "Baixando ${PKG_TARBALL} de ${PKG_URL}"
    if command -v curl >/dev/null 2>&1; then
        curl -fL -o "${PKG_TARBALL}.tmp" "${PKG_URL}"
        mv "${PKG_TARBALL}.tmp" "${PKG_TARBALL}"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${PKG_TARBALL}.tmp" "${PKG_URL}"
        mv "${PKG_TARBALL}.tmp" "${PKG_TARBALL}"
    else
        error "nem curl nem wget encontrados para baixar ${PKG_TARBALL}"
    fi
}

check_sha256() {
    cd "${LFS_SOURCES_DIR}"

    if ! command -v sha256sum >/dev/null 2>&1; then
        log "sha256sum não encontrado; pulando verificação de SHA256 (por sua conta e risco)"
        return
    fi

    if [[ ! -f "${PKG_TARBALL}" ]]; then
        error "tarball ${PKG_TARBALL} não existe para verificação"
    fi

    log "Verificando SHA256 de ${PKG_TARBALL}"
    local sum
    sum="$(sha256sum "${PKG_TARBALL}" | awk '{print $1}')"
    if [[ "${sum}" != "${PKG_SHA256}" ]]; then
        error "SHA256 inválido para ${PKG_TARBALL}:
  esperado: ${PKG_SHA256}
  obtido : ${sum}"
    fi
}

prepare_source() {
    cd "${LFS_SOURCES_DIR}"
    rm -rf "${PKG_NAME}-${PKG_VERSION}"
    tar -xf "${PKG_TARBALL}"
    cd "${PKG_NAME}-${PKG_VERSION}"

    # Instrução do LFS: remover man pages de crypt*, Libxcrypt fornece melhores
    if compgen -G "man3/crypt*" >/dev/null 2>&1; then
        log "Removendo man pages man3/crypt* (fornecidas por libxcrypt)..."
        rm -v man3/crypt* || true
    else
        log "Nenhum man3/crypt* encontrado; nada para remover."
    fi
}

build() {
    # Não há etapa de configure; o pacote é basicamente um conjunto de páginas man.
    log "Nada para compilar em ${PKG_NAME}-${PKG_VERSION} (apenas man pages)."
}

install_pkg() {
    log "Instalando ${PKG_NAME}-${PKG_VERSION} em ${PREFIX}/share/man"

    # LFS usa make prefix=/usr install
    make prefix="${PREFIX}" install
}

package_man_pages() {
    # Empacota apenas as man pages instaladas por este pacote,
    # usando DESTDIR no próprio Makefile do man-pages.
    #
    # Resultado: $ADM_BIN_PKG_DIR/man-pages-<versão>-<arch>.tar.zst

    local bin_dir destdir arch pkgfile srcdir

    bin_dir="${ADM_BIN_PKG_DIR:-${LFS:-/mnt/lfs}/binary-packages}"
    mkdir -p "${bin_dir}"

    # Diretório de build do man-pages (já preparado em prepare_source)
    srcdir="${LFS_SOURCES_DIR}/${PKG_NAME}-${PKG_VERSION}"

    if [[ ! -d "${srcdir}" ]]; then
        log "Diretório de fonte ${srcdir} não existe mais; não é possível empacotar."
        return 0
    fi

    destdir="$(mktemp -d "${TMPDIR:-/tmp}/${PKG_NAME}-pkg.XXXXXX")"

    log "Reinstalando ${PKG_NAME}-${PKG_VERSION} em DESTDIR para empacotamento..."
    (
        cd "${srcdir}"
        # Reaplicamos o mesmo install, mas com DESTDIR para montar a árvore do pacote
        if ! make prefix="${PREFIX}" DESTDIR="${destdir}" install; then
            log "make DESTDIR=${destdir} install falhou; removendo DESTDIR e abortando empacotamento."
            rm -rf "${destdir}"
            return 0
        fi
    )

    # Se não tiver nada em share/man, não empacota
    if [[ ! -d "${destdir}${PREFIX}/share/man" ]]; then
        log "Nenhum conteúdo em ${destdir}${PREFIX}/share/man; nada para empacotar."
        rm -rf "${destdir}"
        return 0
    fi

    arch="$(uname -m)"
    pkgfile="${bin_dir}/${PKG_NAME}-${PKG_VERSION}-${arch}.tar.zst"

    if command -v zstd >/dev/null 2>&1; then
        log "Empacotando ${PKG_NAME}-${PKG_VERSION} em ${pkgfile} ..."
        tar -C "${destdir}" -cf - . | zstd -T0 -19 -o "${pkgfile}.tmp"
        mv -f "${pkgfile}.tmp" "${pkgfile}"
        log "Pacote binário gerado: ${pkgfile}"
    else
        log "zstd não encontrado; pulando empacotamento em .tar.zst (apenas instalação no sistema)."
    fi

    rm -rf "${destdir}"
}

main() {
    select_profile
    fetch_tarball
    check_sha256
    prepare_source
    build
    install_pkg
    package_man_pages

    log "Concluído ${PKG_NAME}-${PKG_VERSION} para perfil ${ADM_PROFILE:-<não-definido>}."
}

main "$@"
