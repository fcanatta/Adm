# Script de build para Glibc-2.42 (Pass 1) no admV2
# Inspirado no LFS 12.4 - cap. 5.5 (Glibc cross) mas:
#   - sem $LFS
#   - sem /tools
#   - encaixado no fluxo do admV2 (DESTDIR + ADM_ROOTFS)

PKG_VERSION="2.42"

# Tarball oficial da glibc 2.42 (formato .tar.xz)
SRC_URL="https://ftp.gnu.org/gnu/glibc/glibc-${PKG_VERSION}.tar.xz"

# Não usamos MD5 (glibc publica SHA256/GPG). Vazio faz o admV2 pular checagem md5.
SRC_MD5=""

pkg_build() {
    # Fornecido pelo admV2:
    #   SRC_DIR  -> fonte já extraída
    #   DESTDIR  -> raiz fake onde 'make install' vai cair
    #   NUMJOBS  -> pode estar setado; se não, caimos em 1
    cd "$SRC_DIR"

    # ------------------------------------------------------------------
    # 1. Preparação: patch FHS (igual ao LFS, mas baixando se não existir)
    # ------------------------------------------------------------------

    local fhs_patch="../glibc-2.42-fhs-1.patch"
    local fhs_url="https://www.linuxfromscratch.org/patches/lfs/development/glibc-2.42-fhs-1.patch"

    if [[ ! -f "$fhs_patch" ]]; then
        echo ">> Baixando patch FHS da Glibc a partir de: $fhs_url"
        if command -v curl >/dev/null 2>&1; then
            curl -L -o "$fhs_patch" "$fhs_url"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "$fhs_patch" "$fhs_url"
        else
            echo "ERRO: nem curl nem wget encontrados para baixar $fhs_patch"
            exit 1
        fi
    fi

    echo ">> Aplicando patch FHS: $fhs_patch"
    patch -Np1 -i "$fhs_patch"

    # ------------------------------------------------------------------
    # 2. Diretório de build dedicado
    # ------------------------------------------------------------------

    rm -rf build
    mkdir -v build
    cd       build

    # ------------------------------------------------------------------
    # 3. Colocar ldconfig e sln em /usr/sbin (configparms)
    # ------------------------------------------------------------------

    echo "rootsbindir=/usr/sbin" > configparms

    # ------------------------------------------------------------------
    # 4. Determinar TARGET_TRIPLET e sysroot
    # ------------------------------------------------------------------

    # TARGET_TRIPLET deve vir do profile (glibc/musl), ex: x86_64-pc-linux-gnu
    : "${TARGET_TRIPLET:=}"

    if [[ -z "$TARGET_TRIPLET" ]]; then
        # fallback: tenta HOST, depois config.guess
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            TARGET_TRIPLET="$("../scripts/config.guess" 2>/dev/null || echo unknown-unknown-linux-gnu)"
        fi
    fi

    echo ">> Glibc Pass 1 alvo: ${TARGET_TRIPLET}"

    # Root do sistema que você está montando (normalmente vem dos profiles)
    : "${ADM_ROOTFS:=/}"

    # Sysroot (equivalente ao $LFS do livro LFS; usado pelo toolchain alvo)
    : "${CROSS_SYSROOT:=${ADM_ROOTFS}}"

    # ------------------------------------------------------------------
    # 5. Flags e paralelismo
    # ------------------------------------------------------------------

    : "${NUMJOBS:=1}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    # Alguns relatos de problemas com make paralelo; se quiser forçar -j1:
    #   GLIBC_MAKE_J1=1 ./admV2.sh build glibc-2.42-pass1
    local glibc_make_jobs="$NUMJOBS"
    if [[ "${GLIBC_MAKE_J1:-0}" = "1" ]]; then
        glibc_make_jobs=1
    fi

    # ------------------------------------------------------------------
    # 6. Configure (modo cross, estilo LFS 5.5, mas sem $LFS) 1
    # ------------------------------------------------------------------

    # GCC cross (TARGET_TRIPLET-gcc) deve estar no PATH (via profile).
    # Ainda assim, se quiser, você pode forçar:
    #   CC=${TARGET_TRIPLET}-gcc ./admV2.sh build glibc-2.42-pass1

    ../configure                               \
        --prefix=/usr                          \
        --host="${TARGET_TRIPLET}"             \
        --build="$("../scripts/config.guess")" \
        --disable-nscd                         \
        libc_cv_slibdir=/usr/lib               \
        --enable-kernel="${GLIBC_MIN_KERNEL:-5.4}"

    # ------------------------------------------------------------------
    # 7. Compilar
    # ------------------------------------------------------------------

    make -j"${glibc_make_jobs}"

    # Em Pass 1 normalmente NÃO rodamos "make check" (é caro e frágil aqui).
    # Se quiser testar mais tarde, use o glibc "final" (tipo pass2 / capítulo 8).

    # ------------------------------------------------------------------
    # 8. Instalar em DESTDIR (pacote do admV2)
    # ------------------------------------------------------------------

    make DESTDIR="$DESTDIR" install

    # ------------------------------------------------------------------
    # 9. Ajustes pós-instalação dentro do DESTDIR
    # ------------------------------------------------------------------

    # 9.1 – Symlinks LSB em lib/lib64, adaptados para DESTDIR
    #       (no livro, usam $LFS/lib e $LFS/lib64) 

    mkdir -p "${DESTDIR}/lib" "${DESTDIR}/lib64"

    case "$(uname -m)" in
        i?86)
            # ld-linux.so.2 -> ld-lsb.so.3 (LSB compat)
            ln -sfv ld-linux.so.2 "${DESTDIR}/lib/ld-lsb.so.3"
        ;;
        x86_64)
            # Compatibilidade dinâmica padrão em /lib64
            ln -sfv ../lib/ld-linux-x86-64.so.2 "${DESTDIR}/lib64/ld-linux-x86-64.so.2"
            ln -sfv ../lib/ld-linux-x86-64.so.2 "${DESTDIR}/lib64/ld-lsb-x86-64.so.3"
        ;;
    esac

    # 9.2 – Ajustar o ldd para não ter /usr hardcoded no RTLDLIST 
    if [[ -f "${DESTDIR}/usr/bin/ldd" ]]; then
        sed '/RTLDLIST=/s@/usr@@g' -i "${DESTDIR}/usr/bin/ldd"
    fi

    # Observação importante:
    # - O pacote resultante terá:
    #     usr/lib/{libc.so.6,...}
    #     usr/bin/ldd
    #     lib/ld-linux*.so.*
    #   Tudo relativo à raiz do sistema alvo.
    # - Na instalação com o admV2, esses caminhos serão extraídos em ADM_ROOTFS.
}
