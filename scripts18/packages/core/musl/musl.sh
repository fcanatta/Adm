#!/usr/bin/env bash
# Build musl-1.2.5 para o adm (build final, dentro do chroot)
# Inclui os dois patches de segurança de 2025-02-13 (iconv EUC-KR + hardening UTF-8).
set -euo pipefail

# Em build final, o adm normalmente roda isso DENTRO do chroot
# com LFS="/". Ainda assim, exigimos LFS para manter o padrão.
: "${LFS:?Variável LFS não definida}"

# Se LFS_SOURCES_DIR não estiver setada dentro do chroot,
# caímos em /sources (padrão LFS) ou $LFS/sources.
SRC_DIR="${LFS_SOURCES_DIR:-${LFS%/}/sources}"

PKG_NAME="musl"
PKG_VER="1.2.5"
PKG_DIR="${PKG_NAME}-${PKG_VER}"
TARBALL="${PKG_DIR}.tar.gz"
URL="https://musl.libc.org/releases/${TARBALL}"

# SHA256 oficial do musl-1.2.5  
TARBALL_SHA256="a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"

PKG_SRC_DIR="${SRC_DIR}/${PKG_DIR}"

log()   { echo "==> [${PKG_NAME}] $*"; }
error() { echo "ERRO [${PKG_NAME}]: $*" >&2; exit 1; }

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "este script precisa ser executado como root (dentro do chroot)"
    fi
}

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

configure_musl() {
    cd "${PKG_SRC_DIR}"

    log "Configurando musl-${PKG_VER} ..."
    # Configuração básica conforme INSTALL do musl:
    #   ./configure --prefix=/usr --syslibdir=/lib
    # Ajustamos mandir também.
    ./configure \
        --prefix=/usr \
        --syslibdir=/lib \
        --mandir=/usr/share/man
}

build_musl() {
    cd "${PKG_SRC_DIR}"
    log "Compilando musl ..."
    make
}

install_musl() {
    cd "${PKG_SRC_DIR}"
    log "Instalando musl em /usr e /lib ..."
    make install

    log "Instalação de musl-${PKG_VER} concluída."
}

main() {
    require_root

    log "Iniciando build de ${PKG_NAME}-${PKG_VER} (final, com patches de segurança de 2025-02-13)"
    log "LFS     = ${LFS}"
    log "SRC_DIR = ${SRC_DIR}"

    ensure_source_dir
    apply_security_patches
    configure_musl
    build_musl
    install_musl

    log "musl-${PKG_VER} instalado com sucesso com os patches de segurança aplicados."
}

main "$@"
