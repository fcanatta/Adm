#!/usr/bin/env bash

# Pacote: musl-1.2.5
# Categoria: core
# Nome: musl
#
# Libc musl final, instalada em /usr + /lib dentro do ROOTFS.
# Inclui suporte para aplicar os dois patches de segurança
# do CVE-2025-26519 no iconv (EUC-KR + hardening UTF-8). 
#
# Espera que linux-api-headers já tenha sido instalado em $ROOTFS/usr/include.

PKG_NAME="musl"
PKG_CATEGORY="core"
PKG_VERSION="1.2.5"
PKG_DESC="musl ${PKG_VERSION} - implementação da libc para Linux (libc principal)"
PKG_HOMEPAGE="https://musl.libc.org/"

# Tarball oficial da musl (link de releases da própria página). 
PKG_SOURCE=(
    "https://musl.libc.org/releases/musl-${PKG_VERSION}.tar.gz"
)

# SHA256 amplamente usada em distros (Ubuntu, musl-cross-make, etc). 
PKG_CHECKSUM_TYPE="sha256"
PKG_CHECKSUMS=(
    "a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"
)

# Dependências lógicas
PKG_DEPENDS=(
    "linux-api-headers"
)

pkg_build() {
    : "${SRC_DIR:?SRC_DIR não definido}"
    : "${BUILD_DIR:?BUILD_DIR não definido}"
    : "${CHOST:?CHOST não definido (ver profile)}"

    echo ">>> [musl] SRC_DIR=${SRC_DIR}"
    echo ">>> [musl] BUILD_DIR=${BUILD_DIR}"
    echo ">>> [musl] CHOST=${CHOST}"

    cd "$SRC_DIR"

    # --------------------------------------------------------------------
    # APLICAÇÃO DOS DOIS PATCHES DE SEGURANÇA (CVE-2025-26519)
    #
    # Você deve baixar os patches da Openwall e salvá-los ao lado do
    # tarball com esses nomes:
    #
    #   musl-1.2.5-iconv-euckr.patch   (patch 1)
    #   musl-1.2.5-iconv-utf8-harden.patch (patch 2)
    #
    #   Patch 1 (EUC-KR validation): 
    #   https://www.openwall.com/lists/musl/2025/02/13/1/1
    #
    #   Patch 2 (hardening UTF-8 output path): 
    #   https://www.openwall.com/lists/musl/2025/02/13/1/2
    #
    # Os patches corrigem o bug de escrita fora de limites em iconv
    # ao converter EUC-KR para UTF-8 e endurecem o caminho de saída
    # UTF-8 contra bugs em decoders.
    # --------------------------------------------------------------------

    local p1 p2
    # Procurar patches no próprio SRC_DIR ou um nível acima
    for f in \
        "musl-1.2.5-iconv-euckr.patch" \
        "../musl-1.2.5-iconv-euckr.patch" \
        "iconv-euckr-cve-2025-26519.patch" \
        "../iconv-euckr-cve-2025-26519.patch"
    do
        [[ -f "$f" ]] && { p1="$f"; break; }
    done

    for f in \
        "musl-1.2.5-iconv-utf8-harden.patch" \
        "../musl-1.2.5-iconv-utf8-harden.patch" \
        "iconv-utf8-harden-cve-2025-26519.patch" \
        "../iconv-utf8-harden-cve-2025-26519.patch"
    do
        [[ -f "$f" ]] && { p2="$f"; break; }
    done

    if [[ -n "${p1:-}" ]]; then
        echo ">>> [musl] Aplicando patch de segurança (EUC-KR): $p1"
        patch -Np1 -i "$p1"
    else
        echo "AVISO [musl]: patch de segurança EUC-KR (p1) não encontrado, musl ficará vulnerável ao CVE-2025-26519."
    fi

    if [[ -n "${p2:-}" ]]; then
        echo ">>> [musl] Aplicando patch de segurança (UTF-8 hardening): $p2"
        patch -Np1 -i "$p2"
    else
        echo "AVISO [musl]: patch de segurança UTF-8 hardening (p2) não encontrado, musl ficará vulnerável ao CVE-2025-26519."
    fi

    # Diretório de build separado
    mkdir -pv "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Configuração:
    #
    #   --prefix=/usr   -> headers em /usr/include, libs em /usr/lib
    #   --syslibdir=/lib -> dynamic linker ld-musl-*.so.1 em /lib
    #   --target=$CHOST -> triplet musl (ex: x86_64-linux-musl) 
    #
    # Musl trata --host e --target como sinônimos.

    ../configure \
        --prefix=/usr  \
        --syslibdir=/lib \
        --target="$CHOST"

    # Compila
    make -j"${ADM_JOBS:-$(nproc)}"
}

pkg_install() {
    : "${BUILD_DIR:?BUILD_DIR não definido}"
    : "${DESTDIR:?DESTDIR não definido}"

    cd "$BUILD_DIR"

    # Instala embaixo de DESTDIR (ADM depois sincroniza com ROOTFS)
    make DESTDIR="$DESTDIR" install

    # Apenas garantir que /lib exista (em caso de DESTDIR "vazio")
    mkdir -pv "$DESTDIR/lib"

    # Opcional: criar um ldd bem simples usando o ld-musl do target
    # (se ainda não existir). Isso ajuda debug/diagnóstico em ambiente musl.
    if [[ -d "$DESTDIR/lib" ]]; then
        local ld_musl
        ld_musl="$(cd "$DESTDIR/lib" && ls ld-musl-*.so.1 2>/dev/null | head -n1 || true)"
        if [[ -n "$ld_musl" ]]; then
            mkdir -pv "$DESTDIR/usr/bin"
            if [[ ! -e "$DESTDIR/usr/bin/ldd" ]]; then
                cat > "$DESTDIR/usr/bin/ldd" <<EOF
#!/usr/bin/env sh
exec /lib/${ld_musl} --list "\$@"
EOF
                chmod 0755 "$DESTDIR/usr/bin/ldd"
            fi
        fi
    fi
}
