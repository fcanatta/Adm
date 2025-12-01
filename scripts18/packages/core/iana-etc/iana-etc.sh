#!/usr/bin/env bash
# Build iana-etc-20251120 para o adm
#
# Fonte: Mic92/iana-etc (GitHub), release 20251120.
# O pacote fornece dados para /etc/services e /etc/protocols,
# equivalente ao Iana-Etc do LFS, mas com dados atualizados.
#
# Lógica:
#   - Baixa iana-etc-20251120.tar.gz
#   - Verifica SHA256
#   - Extrai em um diretório isolado
#   - Procura arquivos "services" e "protocols" em até 5 níveis de profundidade
#   - Copia para /etc/services e /etc/protocols
#
# Perfis suportados:
#   ADM_PROFILE=glibc-final
#   ADM_PROFILE=musl-final
#
# Instala DIRETAMENTE em /etc do chroot. Não usa PREFIX.

set -euo pipefail

PKG_NAME="iana-etc"
PKG_VERSION="20251120"
PKG_TARBALL="${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_URL="https://github.com/Mic92/iana-etc/releases/download/${PKG_VERSION}/${PKG_TARBALL}"

# SHA256 oficial do tarball (da página de releases do GitHub)
PKG_SHA256="57213602d1874f01a424a0c6088fe8830a2343cea65356a6d45b1396fd855999"

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
            # Para iana-etc, o alvo é sempre /etc do sistema,
            # independentemente da libc, mas verificamos o perfil
            # para evitar uso incorreto.
            log "Perfil selecionado: ${profile} (instalação em /etc)"
            ;;
        *)
            error "ADM_PROFILE='${profile}' não suportado para ${PKG_NAME}.
Use glibc-final ou musl-final dentro do chroot apropriado."
            ;;
    esac
}

# -------------------------------------------------------------
# Download e verificação
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

# -------------------------------------------------------------
# Extração e descoberta de serviços/protocols
# -------------------------------------------------------------

SRC_DIR=""

prepare_source() {
    cd "${LFS_SOURCES_DIR}"

    # Diretório isolado para não misturar com outras coisas
    rm -rf "${PKG_NAME}-${PKG_VERSION}.src"
    mkdir -p "${PKG_NAME}-${PKG_VERSION}.src"
    cd "${PKG_NAME}-${PKG_VERSION}.src"

    log "Extraindo ${PKG_TARBALL} em ${PWD}"
    tar -xf "../${PKG_TARBALL}"

    # Descobrir diretório que contém ambos: services e protocols
    find_services_protocols_dir
}

find_services_protocols_dir() {
    local candidate_dir=""
    local path

    SRC_ETC_DIR=""

    # Procura por arquivos chamados "services" (até 5 níveis)
    while IFS= read -r path; do
        candidate_dir="$(dirname "${path}")"
        if [[ -f "${candidate_dir}/services" && -f "${candidate_dir}/protocols" ]]; then
            SRC_ETC_DIR="${candidate_dir}"
            break
        fi
    done < <(find . -maxdepth 5 -type f -name "services" -print || true)

    if [[ -z "${SRC_ETC_DIR}" ]]; then
        error "Não foi possível encontrar arquivos 'services' e 'protocols' no tarball ${PKG_TARBALL}"
    fi

    log "Encontrado diretório com services/protocols: ${SRC_ETC_DIR}"
}

# -------------------------------------------------------------
# Instalação
# -------------------------------------------------------------

install_pkg() {
    cd "${LFS_SOURCES_DIR}/${PKG_NAME}-${PKG_VERSION}.src"

    if [[ -z "${SRC_ETC_DIR:-}" ]]; then
        error "SRC_ETC_DIR não definido antes da instalação (bug no script)"
    fi

    local services_file="${SRC_ETC_DIR}/services"
    local protocols_file="${SRC_ETC_DIR}/protocols"

    if [[ ! -f "${services_file}" ]]; then
        error "Arquivo 'services' não encontrado em ${services_file}"
    fi
    if [[ ! -f "${protocols_file}" ]]; then
        error "Arquivo 'protocols' não encontrado em ${protocols_file}"
    fi

    log "Instalando /etc/services e /etc/protocols"

    install -Dm644 "${services_file}"  "/etc/services"
    install -Dm644 "${protocols_file}" "/etc/protocols"

    local license_path=""
    license_path="$(find . -maxdepth 4 -type f -name 'LICENSE' -print | head -n1 || true)"
    if [[ -n "${license_path}" ]]; then
        log "Instalando LICENSE em /usr/share/licenses/${PKG_NAME}/LICENSE"
        install -Dm644 "${license_path}" "/usr/share/licenses/${PKG_NAME}/LICENSE"
    else
        log "LICENSE não encontrado no tarball; pulando instalação de licença."
    fi
}

package_iana_etc() {
    # Empacota os arquivos instalados em /etc/services e /etc/protocols
    # em um tar.zst em $ADM_BIN_PKG_DIR (ou $LFS/binary-packages por padrão).

    # Garante caminho de saída para pacotes binários
    local bin_dir destdir arch pkgfile
    bin_dir="${ADM_BIN_PKG_DIR:-${LFS:-/mnt/lfs}/binary-packages}"
    mkdir -p "${bin_dir}"

    # Cria DESTDIR temporário
    destdir="$(mktemp -d "${TMPDIR:-/tmp}/${PKG_NAME}-pkg.XXXXXX")"

    # Copia os arquivos instalados para o DESTDIR
    if [[ -f /etc/services ]]; then
        install -Dm644 /etc/services  "${destdir}/etc/services"
    else
        log "Aviso: /etc/services não existe; nada para empacotar."
    fi

    if [[ -f /etc/protocols ]]; then
        install -Dm644 /etc/protocols "${destdir}/etc/protocols"
    else
        log "Aviso: /etc/protocols não existe; nada para empacotar."
    fi

    # Se nenhum arquivo foi copiado, não gera pacote
    if [[ ! -e "${destdir}/etc/services" && ! -e "${destdir}/etc/protocols" ]]; then
        log "Nenhum arquivo encontrado para empacotar; DESTDIR vazio. Cancelando empacotamento."
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
    install_pkg
    package_iana_etc

    log "Concluído ${PKG_NAME}-${PKG_VERSION} para perfil ${ADM_PROFILE:-<não-definido>}."
}

main "$@"
