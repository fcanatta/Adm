# Script de build para Linux-6.17.9 API Headers no admV2
# Inspirado nas instruções do LFS 12.x para Linux API Headers,
# mas sem $LFS: usamos DESTDIR (do admV2) e ADM_ROOTFS na instalação final. 0

PKG_VERSION="6.17.9"

# Tarball do kernel 6.x no kernel.org (padrão v6.x)
SRC_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${PKG_VERSION}.tar.xz"

# Não usamos MD5 aqui; kernel.org publica SHA256/GPG. Deixar vazio pula checagem de md5 no admV2.
SRC_MD5=""

pkg_build() {
    # Variáveis fornecidas pelo admV2:
    #   SRC_DIR  -> diretório do source do kernel já extraído
    #   DESTDIR  -> root fake usado para "instalar" dentro do pacote
    #   NUMJOBS  -> opcional, número de jobs (não é crítico aqui)
    cd "$SRC_DIR"

    # Opcional: permitir escolher a ARCH explicitamente (senão o kernel detecta sozinho)
    # Exemplo de uso:
    #   KERNEL_ARCH=x86_64 ./admV2.sh build linux-6.17.9-api-headers
    local make_arch=()
    if [[ -n "${KERNEL_ARCH:-}" ]]; then
        make_arch=( "ARCH=${KERNEL_ARCH}" )
        echo ">> Usando ARCH=${KERNEL_ARCH} para os headers do kernel"
    fi

    echo ">> Limpando árvore do kernel (make mrproper)..."
    make "${make_arch[@]}" mrproper

    echo ">> Gerando headers sanitizados (make headers)..."
    make "${make_arch[@]}" headers

    # A partir daqui seguimos a lógica LFS moderna:
    # - remover arquivos que não são .h em usr/include
    # - copiar apenas os headers "user-visible" 1
    echo ">> Limpando arquivos não-.h em usr/include..."
    find usr/include -type f ! -name '*.h' -delete

    # Garante que o diretório de destino exista dentro do DESTDIR do pacote
    mkdir -p "${DESTDIR}/usr"

    echo ">> Copiando headers para ${DESTDIR}/usr/include..."
    # Isso resulta em DESTDIR/usr/include/{linux,asm,asm-generic,...}
    cp -rv usr/include "${DESTDIR}/usr"
}
