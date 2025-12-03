# Script de build para GNU patch 2.8 (pass1) no admV2

# Versão “real” do patch; o “pass1” fica só no nome do pacote/diretório
PKG_VERSION="2.8"

# Fonte oficial (espelho GNU). Pode ser .tar.gz ou .tar.xz; aqui .tar.xz.
SRC_URL="https://ftpmirror.gnu.org/gnu/patch/patch-${PKG_VERSION}.tar.xz"

# O projeto publica SHA256, não MD5. Deixando vazio, o admV2 NÃO faz verificação de md5.
SRC_MD5=""

# Função chamada pelo admV2 depois de preparar SRC_DIR e DESTDIR
pkg_build() {
    # Esses dois vêm do admV2
    cd "$SRC_DIR"

    # Detecta prefix de instalação de forma determinística:
    # 1) PATCH_PREFIX se definido
    # 2) $LFS/tools se existir
    # 3) /tools se existir
    # 4) /usr (padrão)
    local prefix

    if [[ -n "${PATCH_PREFIX:-}" ]]; then
        prefix="$PATCH_PREFIX"
    elif [[ -n "${LFS:-}" && -d "${LFS}/tools" ]]; then
        prefix="${LFS}/tools"
    elif [[ -d /tools ]]; then
        prefix="/tools"
    else
        prefix="/usr"
    fi

    echo ">> Usando prefix de instalação para patch: ${prefix}"

    # Algumas toolchains definem HOST/TARGET; se não vier nada, fica vazio mesmo (build nativo)
    : "${HOST:=}"
    : "${TARGET:=}"

    # Flags padrão de compilação se não vierem de fora
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    # Número de jobs paralelos, vem do admV2 (NUMJOBS) ou cai em 1
    : "${NUMJOBS:=1}"

    # Configure típico do GNU patch.
    # Se você estiver em cross, pode passar HOST/TARGET via ambiente:
    #   HOST=x86_64-lfs-linux-musl ./admV2.sh build patch-pass1
    ./configure \
        ${HOST:+--host="$HOST"} \
        ${TARGET:+--target="$TARGET"} \
        --prefix="${prefix}" \
        --sysconfdir=/etc \
        --disable-nls

    # Compila
    make -j"${NUMJOBS}"

    # Para “pass1” normalmente não rodamos testes
    # Se quiser rodar, descomente:
    # make check

    # Instala dentro de DESTDIR; o admV2 depois empacota esse DESTDIR
    make DESTDIR="$DESTDIR" install
}
