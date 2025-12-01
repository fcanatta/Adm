#!/usr/bin/env bash
# Build musl-1.2.5 para o adm
# - Usa ADM_PROFILE para decidir o modo:
#     musl-final → musl como libc principal do sistema (libc nativa)
# - Aplica os dois patches de segurança de 2025-02-13 (iconv EUC-KR + hardening UTF-8)
#
# O perfil padrão vem de /etc/adm.conf, por exemplo:
#   ADM_PROFILE="musl-final"

set -euo pipefail

: "${LFS:?Variável LFS não definida}"
: "${LFS_SOURCES_DIR:?Variável LFS_SOURCES_DIR não definida}"

PKG_NAME="musl"
PKG_VER="1.2.5"
PKG_DIR="${PKG_NAME}-${PKG_VER}"
TARBALL="${PKG_DIR}.tar.gz"
URL="https://musl.libc.org/releases/${TARBALL}"

# SHA256 oficial do musl-1.2.5
TARBALL_SHA256="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

SRC_DIR="${LFS_SOURCES_DIR}"
PKG_SRC_DIR="${SRC_DIR}/${PKG_DIR}"

log()   { echo "==> [${PKG_NAME}] $*"; }
error() { echo "ERRO [${PKG_NAME}]: $*" >&2; exit 1; }

# -------------------------------------------------------------
#  Seleção de perfil (aqui só aceitamos musl-final)
# -------------------------------------------------------------

select_profile() {
    local profile="${ADM_PROFILE:-musl-final}"

    case "$profile" in
        musl-final)
            BUILD_MODE="musl-final"
            # musl como libc principal do sistema
            MUSL_PREFIX="${ADM_PREFIX:-/usr}"
            MUSL_SYSLIBDIR="/lib"
            MUSL_MANDIR="${MUSL_PREFIX}/share/man"
            ;;
        *)
            error "ADM_PROFILE='$profile' inválido para musl.
Use ADM_PROFILE='musl-final' em /etc/adm.conf para construir o musl como libc principal."
            ;;
    esac

    log "Perfil selecionado: ${profile} (BUILD_MODE=${BUILD_MODE})"
    log "  MUSL_PREFIX   = ${MUSL_PREFIX}"
    log "  MUSL_SYSLIBDIR= ${MUSL_SYSLIBDIR}"
    log "  MUSL_MANDIR   = ${MUSL_MANDIR}"
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
#  Aplicar patches de segurança (Openwall 2025-02-13)
# -------------------------------------------------------------

apply_security_patches() {
    cd "${PKG_SRC_DIR}"

    log "Aplicando patch 1/2: correção do decoder EUC-KR em iconv.c ..."
    patch -p1 <<'EOF'
diff --git a/src/locale/iconv.c b/src/locale/iconv.c
index 9605c8e9..008c93f0 100644
--- a/src/locale/iconv.c
+++ b/src/locale/iconv.c
@@ -502,7 +502,7 @@ size_t iconv(iconv_t cd, char **restrict in, size_t *restrict inb, char **restri
 		if (c >= 93 || d >= 94) {
 			c += (0xa1-0x81);
 			d += 0xa1;
-			if (c >= 93 || c>=0xc6-0x81 && d>0x52)
+			if (c > 0xc6-0x81 || c==0xc6-0x81 && d>0x52)
 				goto ilseq;
 			if (d-'A'<26) d = d-'A';
 			else if (d-'a'<26) d = d-'a'+26;
EOF

    log "Aplicando patch 2/2: hardening do caminho de saída UTF-8 em iconv.c ..."
    patch -p1 <<'EOF'
diff --git a/src/locale/iconv.c b/src/locale/iconv.c
index 008c93f0..52178950 100644
--- a/src/locale/iconv.c
+++ b/src/locale/iconv.c
@@ -545,6 +545,10 @@ size_t iconv(iconv_t cd, char **restrict in, size_t *restrict inb, char **restri
 			if (*outb < k) goto toobig;
 			memcpy(*out, tmp, k);
 		} else k = wctomb_utf8(*out, c);
+		/* Esta condição de falha deveria ser inalcançável, mas
+		 * é incluída para impedir que bugs no decoder resultem
+		 * em avanços fora da faixa do buffer de saída. */
+		if (k>4) goto ilseq;
 		*out += k;
 		*outb -= k;
 		break;
EOF
}

# -------------------------------------------------------------
#  Configura, compila, instala
# -------------------------------------------------------------

configure_musl() {
    cd "${PKG_SRC_DIR}"

    log "Configurando musl-${PKG_VER} (BUILD_MODE=${BUILD_MODE}) ..."
    ./configure \
        --prefix="${MUSL_PREFIX}" \
        --syslibdir="${MUSL_SYSLIBDIR}" \
        --mandir="${MUSL_MANDIR}"
}

build_musl() {
    cd "${PKG_SRC_DIR}"
    log "Compilando musl ..."
    make
}

install_musl() {
    cd "${PKG_SRC_DIR}"
    log "Instalando musl em ${MUSL_PREFIX} e ${MUSL_SYSLIBDIR} ..."
    make install

    log "Instalação de musl-${PKG_VER} concluída (BUILD_MODE=${BUILD_MODE})."
    log "ATENÇÃO: musl como libc principal vai afetar TODO o sistema;
garanta que binutils/gcc e os demais pacotes estejam alinhados para musl."
}

main() {
    log "Iniciando build de ${PKG_NAME}-${PKG_VER}"

    select_profile
    ensure_source_dir
    apply_security_patches
    configure_musl
    build_musl
    install_musl

    log "musl-${PKG_VER} instalado com sucesso."
}

main "$@"
