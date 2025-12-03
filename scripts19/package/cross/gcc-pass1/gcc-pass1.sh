# Script de build para GNU GCC 15.2.0 (Pass 1) no admV2
# Cross-compiler inicial, inspirado no LFS 12.4, mas:
#  - sem $LFS
#  - sem /tools do livro
#  - usando TARGET_TRIPLET, ADM_ROOTFS, CROSS_PREFIX, CROSS_SYSROOT

PKG_VERSION="15.2.0"

# Tarball oficial do GCC 15.2.0 (formato .tar.xz)
SRC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
SRC_MD5=""   # deixamos vazio: admV2 não faz checagem de md5

pkg_build() {
    # Variáveis fornecidas pelo admV2:
    #   SRC_DIR  -> diretório do source do GCC já extraído
    #   DESTDIR  -> root fake usado para make install
    #   NUMJOBS  -> número de jobs paralelos (já definido pelo adm ou pelo profile)
    cd "$SRC_DIR"

    # ======= Versões das libs internas usadas pelo GCC ========

    local MPFR_VER="4.2.2"
    local GMP_VER="6.3.0"
    local MPC_VER="1.3.1"

    local MPFR_TAR="mpfr-${MPFR_VER}.tar.xz"
    local GMP_TAR="gmp-${GMP_VER}.tar.xz"
    local MPC_TAR="mpc-${MPC_VER}.tar.gz"

    # Helper simples para baixar um tarball se não existir
    _fetch_if_missing() {
        local url="$1"
        local out="$2"

        if [[ -f "../$out" ]]; then
            return 0
        fi

        echo ">> Baixando $out de $url"
        if command -v curl >/dev/null 2>&1; then
            curl -L -o "../$out" "$url"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "../$out" "$url"
        else
            echo "ERRO: nem curl nem wget encontrados para baixar $out"
            exit 1
        fi
    }

    # Baixa mpfr/gmp/mpc se necessário (diretório pai de SRC_DIR é onde os tarballs ficam)
    _fetch_if_missing "https://ftp.gnu.org/gnu/mpfr/${MPFR_TAR}" "$MPFR_TAR"
    _fetch_if_missing "https://ftp.gnu.org/gnu/gmp/${GMP_TAR}"   "$GMP_TAR"
    _fetch_if_missing "https://ftp.gnu.org/gnu/mpc/${MPC_TAR}"   "$MPC_TAR"

    # Só descompacta/renomeia se os diretórios ainda não existem
    if [[ ! -d mpfr ]]; then
        echo ">> Incorporando MPFR ${MPFR_VER} ao tree do GCC"
        tar -xf "../${MPFR_TAR}"
        mv -v "mpfr-${MPFR_VER}" mpfr
    fi

    if [[ ! -d gmp ]]; then
        echo ">> Incorporando GMP ${GMP_VER} ao tree do GCC"
        tar -xf "../${GMP_TAR}"
        mv -v "gmp-${GMP_VER}" gmp
    fi

    if [[ ! -d mpc ]]; then
        echo ">> Incorporando MPC ${MPC_VER} ao tree do GCC"
        tar -xf "../${MPC_TAR}"
        mv -v "mpc-${MPC_VER}" mpc
    fi

    # ======= Ajuste de lib64 -> lib em x86_64 ========
    # Mesmo sed que o LFS usa (em 12.4) para GCC pass1 em x86_64.
    case "$(uname -m)" in
        x86_64)
            sed -e '/m64=/s/lib64/lib/' \
                -i gcc/config/i386/t-linux64
        ;;
    esac

    # ======= Alvo (TARGET_TRIPLET) e sysroot ========

    # TARGET_TRIPLET deve vir do profile (glibc/musl), mas garantimos um fallback.
    : "${TARGET_TRIPLET:=}"

    if [[ -z "$TARGET_TRIPLET" ]]; then
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            TARGET_TRIPLET="$(./config.guess 2>/dev/null || echo unknown-unknown-linux-gnu)"
        fi
    fi

    echo ">> GCC Pass 1 alvo: $TARGET_TRIPLET"

    # Root do sistema que você está construindo (vem do profile / admV2)
    : "${ADM_ROOTFS:=/}"

    # Sysroot alvo que o GCC vai usar para procurar includes/libs do sistema alvo
    : "${CROSS_SYSROOT:=$ADM_ROOTFS}"

    # Prefixo dos binários de cross (PARECIDO com $LFS/tools do livro, mas aqui é genérico):
    : "${CROSS_PREFIX:=/cross-tools}"

    echo ">> GCC Pass 1 prefix (no alvo): $CROSS_PREFIX"
    echo ">> GCC Pass 1 sysroot alvo    : $CROSS_SYSROOT"

    # ======= Flags de compilação / paralelismo ========

    : "${NUMJOBS:=1}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    # ======= Opção --with-glibc-version (só se estiver em perfil glibc) ========

    local glibc_opt=()
    # PROFILE normalmente vem dos profiles profile-glibc.sh / profile-musl.sh
    case "${PROFILE:-glibc}" in
        glibc)
            # versão do glibc alvo; pode ajustar com GLIBC_TARGET_VERSION
            local _glibc_ver="${GLIBC_TARGET_VERSION:-2.42}"
            glibc_opt=( "--with-glibc-version=${_glibc_ver}" )
        ;;
        *)
            # para musl ou outros alvos, não usamos --with-glibc-version
        ;;
    esac

    # ======= Build em diretório separado ========

    rm -rf build
    mkdir -v build
    cd       build

    # Configure baseado no LFS 12.4 GCC Pass 1 (adaptado)
    ../configure \
        --target="${TARGET_TRIPLET}" \
        --prefix="${CROSS_PREFIX}" \
        --with-sysroot="${CROSS_SYSROOT}" \
        "${glibc_opt[@]}" \
        --with-newlib \
        --without-headers \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdcxx \
        --enable-languages=c,c++

    # Compila o cross-compiler
    make -j"${NUMJOBS}"

    # Instala no DESTDIR preparado pelo admV2.
    # No pacote final, isso vira:
    #   ${ADM_ROOTFS}${CROSS_PREFIX}/bin/${TARGET_TRIPLET}-gcc
    make DESTDIR="$DESTDIR" install

    # ======= Gerar limits.h "completo" para o cross-compiler ========
    # Igual ao que o LFS faz, mas respeitando DESTDIR e CROSS_PREFIX. 2

    cd ..

    local gcc_prog="${DESTDIR}${CROSS_PREFIX}/bin/${TARGET_TRIPLET}-gcc"
    if [[ ! -x "$gcc_prog" ]]; then
        echo "AVISO: não encontrei ${gcc_prog} para gerar limits.h; verifique a instalação do GCC pass1."
        return 0
    fi

    local libgcc_file libgcc_dir
    libgcc_file="$("$gcc_prog" -print-libgcc-file-name 2>/dev/null || true)"
    if [[ -z "$libgcc_file" ]]; then
        echo "AVISO: ${gcc_prog} -print-libgcc-file-name não retornou caminho; pulando geração de limits.h."
        return 0
    fi

    libgcc_dir="$(dirname "$libgcc_file")"

    echo ">> Gerando limits.h em ${libgcc_dir}/include/limits.h"

    mkdir -p "${libgcc_dir}/include"
    cat gcc/limitx.h gcc/glimits.h gcc/limity.h > "${libgcc_dir}/include/limits.h"
}
