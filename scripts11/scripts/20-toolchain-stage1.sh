#!/usr/bin/env bash
# 20-toolchain-stage1.sh
# Construção do cross-toolchain + temporary tools (stage1) para o ADM.
#
# Responsabilidades:
#   - Preparar diretórios de build para cross-toolchain:
#       /usr/src/adm/cross-toolchain/
#           build/
#           sysroot/
#           logs/
#   - Construir:
#       * binutils (passo 1)
#       * gcc (passo 1 - sem libs completas)
#       * headers do kernel (para libc)
#       * libc inicial (glibc/musl, conforme ADM_LIBC)
#       * gcc final do cross
#   - Construir temporary tools (stage1) no rootfs-stage1:
#       /usr/src/adm/rootfs-stage1/
#           tools/ (ou /usr, conforme estratégia)
#
# Ele tenta usar:
#   - 00-env-profiles.sh   (ADM_TARGET, ADM_HOST, ADM_BUILD, ADM_PROFILE, etc.)
#   - 01-log-ui.sh         (adm_stage, adm_info, adm_warn, adm_error, adm_run_with_spinner)
#   - 13-binary-cache.sh   (cache de binários, opcional)
#
# Não há erros silenciosos: tudo que for importante é checado e logado.
# ----------------------------------------------------------------------
# Requisitos e modo seguro
# ----------------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 20-toolchain-stage1.sh requer bash." >&2
    exit 1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERRO: 20-toolchain-stage1.sh requer bash >= 4." >&2
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'
# ----------------------------------------------------------------------
# Integração com ambiente e logging
# ----------------------------------------------------------------------
ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"

ADM_SCRIPTS="${ADM_SCRIPTS:-$ADM_ROOT/scripts}"
ADM_REPO="${ADM_REPO:-$ADM_ROOT/repo}"
ADM_WORK="${ADM_WORK:-$ADM_ROOT/work}"
ADM_SOURCES="${ADM_SOURCES:-$ADM_ROOT/sources}"

ADM_CROSS_ROOT="${ADM_CROSS_ROOT:-$ADM_ROOT/cross-toolchain}"
ADM_CROSS_BUILD="${ADM_CROSS_BUILD:-$ADM_CROSS_ROOT/build}"
ADM_CROSS_SYSROOT="${ADM_CROSS_SYSROOT:-$ADM_CROSS_ROOT/sysroot}"
ADM_CROSS_LOGS="${ADM_CROSS_LOGS:-$ADM_CROSS_ROOT/logs}"

ADM_ROOTFS_STAGE1="${ADM_ROOTFS_STAGE1:-$ADM_ROOT/rootfs-stage1}"

# Vars do profile (esperado que venham de 00-env-profiles.sh)
ADM_PROFILE="${ADM_PROFILE:-normal}"
ADM_TARGET="${ADM_TARGET:-$(uname -m 2>/dev/null || echo unknown)-unknown-linux-gnu}"
ADM_HOST="${ADM_HOST:-$ADM_TARGET}"
ADM_BUILD="${ADM_BUILD:-$ADM_TARGET}"
ADM_LIBC="${ADM_LIBC:-glibc}"
ADM_SYSROOT="${ADM_SYSROOT:-$ADM_CROSS_SYSROOT}"

# Logging: se 01-log-ui.sh já foi carregado, usamos as funções bonitas.
# Caso contrário, definimos fallback simples.
if ! declare -F adm_info >/dev/null 2>&1; then
    adm_log_ts() { date +"%Y-%m-%d %H:%M:%S"; }
    adm_info()   { printf '[%s] [INFO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_warn()   { printf '[%s] [WARN] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_error()  { printf '[%s] [ERRO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_die()    { adm_error "$*"; exit 1; }
fi

if ! declare -F adm_stage >/dev/null 2>&1; then
    adm_stage() { adm_info "===== STAGE: $* ====="; }
fi

if ! declare -F adm_ensure_dir >/dev/null 2>&1; then
    adm_ensure_dir() {
        local d="${1:-}"
        if [ -z "$d" ]; then
            adm_die "adm_ensure_dir chamado com caminho vazio"
        fi
        if [ -d "$d" ]; then
            return 0
        fi
        if ! mkdir -p "$d"; then
            adm_die "Falha ao criar diretório: $d"
        fi
    }
fi

# spinner / run_with_spinner (se existir)
if ! declare -F adm_run_with_spinner >/dev/null 2>&1; then
    adm_run_with_spinner() {
        # fallback sem spinner
        local msg="$1"; shift
        adm_info "$msg"
        "$@"
    }
fi

# ----------------------------------------------------------------------
# Helpers de ambiente / paths
# ----------------------------------------------------------------------

adm_toolchain_init_paths() {
    adm_ensure_dir "$ADM_CROSS_ROOT"
    adm_ensure_dir "$ADM_CROSS_BUILD"
    adm_ensure_dir "$ADM_CROSS_SYSROOT"
    adm_ensure_dir "$ADM_CROSS_LOGS"
    adm_ensure_dir "$ADM_ROOTFS_STAGE1"
    adm_ensure_dir "$ADM_WORK"
    adm_ensure_dir "$ADM_SOURCES"
}

adm_toolchain_logfile_for() {
    # Gera nome de log para uma etapa do toolchain
    local name="${1:-}"
    [ -z "$name" ] && name="step"
    printf '%s/%s-%s.log' "$ADM_CROSS_LOGS" "$name" "$(date +"%Y%m%d-%H%M%S")"
}

adm_toolchain_host_triplet() {
    # Usa ADM_HOST se existir, senão tenta deduzir
    if [ -n "${ADM_HOST:-}" ]; then
        printf '%s' "$ADM_HOST"
        return 0
    fi
    uname -m 2>/dev/null || echo "unknown"
}

# ----------------------------------------------------------------------
# Pré-requisitos do host (stage 0)
# ----------------------------------------------------------------------

adm_toolchain_check_host_prereqs() {
    adm_stage "Stage 0 - Verificação do host"

    local required_bins=(
        bash
        gcc
        g++
        make
        awk
        sed
        grep
        tar
        xz
        bzip2
        gzip
        file
        patch
        pkg-config
        ld
        ar
        ranlib
    )

    local missing=()
    local bin
    for bin in "${required_bins[@]}"; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            missing+=("$bin")
        fi
    done

    if [ "${#missing[@]}" -ne 0 ]; then
        adm_error "Ferramentas obrigatórias ausentes no host:"
        local m
        for m in "${missing[@]}"; do
            adm_error "  - $m"
        done
        adm_die "Instale os pré-requisitos do host antes de construir o toolchain."
    fi

    adm_info "Host atende aos pré-requisitos mínimos para o toolchain."
}

# ----------------------------------------------------------------------
# Helpers para baixar/extrair fontes (sem duplicar 30-source-manager)
# ----------------------------------------------------------------------

adm_toolchain_source_dir_for() {
    # Diretório de work para um pacote do toolchain
    # Uso: adm_toolchain_source_dir_for binutils-2.43.1 => /usr/src/adm/work/binutils-2.43.1
    local pkg="${1:-}"
    [ -z "$pkg" ] && adm_die "adm_toolchain_source_dir_for requer nome do pacote"
    printf '%s/%s' "$ADM_WORK" "$pkg"
}

adm_toolchain_extract_tarball() {
    # Extrai um tarball em um diretório de work.
    # Uso: adm_toolchain_extract_tarball /usr/src/adm/sources/binutils-2.43.1.tar.xz binutils-2.43.1
    local tarball="${1:-}"
    local workname="${2:-}"

    [ -z "$tarball" ] && adm_die "adm_toolchain_extract_tarball requer tarball"
    [ -z "$workname" ] && adm_die "adm_toolchain_extract_tarball requer workname"

    if [ ! -f "$tarball" ]; then
        adm_die "Tarball não encontrado: $tarball"
    fi

    local workdir
    workdir="$(adm_toolchain_source_dir_for "$workname")"

    # Remove qualquer resto antigo daquele workdir
    if [ -d "$workdir" ]; then
        adm_info "Limpando diretório de trabalho antigo: $workdir"
        rm -rf --one-file-system "$workdir" || adm_die "Falha ao limpar $workdir"
    fi

    adm_ensure_dir "$workdir"

    adm_info "Extraindo $tarball para $workdir"
    case "$tarball" in
        *.tar.xz)
            if ! tar -xJf "$tarball" -C "$ADM_WORK"; then
                adm_die "Falha ao extrair $tarball"
            fi
            ;;
        *.tar.gz|*.tgz)
            if ! tar -xzf "$tarball" -C "$ADM_WORK"; then
                adm_die "Falha ao extrair $tarball"
            fi
            ;;
        *.tar.bz2)
            if ! tar -xjf "$tarball" -C "$ADM_WORK"; then
                adm_die "Falha ao extrair $tarball"
            fi
            ;;
        *.tar.zst)
            if ! command -v zstd >/dev/null 2>&1; then
                adm_die "Tarball é .tar.zst mas 'zstd' não está disponível"
            fi
            if ! zstd -d -c "$tarball" | tar -xf - -C "$ADM_WORK"; then
                adm_die "Falha ao extrair $tarball"
            fi
            ;;
        *)
            adm_die "Formato de tarball não suportado: $tarball"
            ;;
    esac

    # Em muitos pacotes, o tarball cria um diretório com o mesmo nome
    if [ ! -d "$workdir" ]; then
        # Tenta achar outro dir parecido
        local candidate
        candidate="$(tar -tf "$tarball" | head -n 1 | cut -d/ -f1)"
        if [ -n "$candidate" ] && [ -d "$ADM_WORK/$candidate" ]; then
            mv "$ADM_WORK/$candidate" "$workdir" || adm_die "Falha ao renomear $candidate -> $workdir"
        else
            adm_die "Não foi possível localizar diretório de trabalho após extrair $tarball"
        fi
    fi
}

# ----------------------------------------------------------------------
# Construção do cross-toolchain
# ----------------------------------------------------------------------
# Para não amarrar a script em versões específicas, usamos variáveis
# com defaults razoáveis. Você pode sobrescrever via ambiente.

TC_BINUTILS_PKG="${TC_BINUTILS_PKG:-binutils-2.43.1}"
TC_BINUTILS_TARBALL="${TC_BINUTILS_TARBALL:-$ADM_SOURCES/${TC_BINUTILS_PKG}.tar.xz}"

TC_GCC_PKG="${TC_GCC_PKG:-gcc-14.2.0}"
TC_GCC_TARBALL="${TC_GCC_TARBALL:-$ADM_SOURCES/${TC_GCC_PKG}.tar.xz}"

TC_LINUX_PKG="${TC_LINUX_PKG:-linux-6.12.0}"
TC_LINUX_TARBALL="${TC_LINUX_TARBALL:-$ADM_SOURCES/${TC_LINUX_PKG}.tar.xz}"

TC_GLIBC_PKG="${TC_GLIBC_PKG:-glibc-2.40}"
TC_GLIBC_TARBALL="${TC_GLIBC_TARBALL:-$ADM_SOURCES/${TC_GLIBC_PKG}.tar.xz}"

# Se ADM_LIBC=musl, variáveis equivalentes poderiam ser usadas (não detalhamos).
TC_MUSL_PKG="${TC_MUSL_PKG:-musl-1.2.5}"
TC_MUSL_TARBALL="${TC_MUSL_TARBALL:-$ADM_SOURCES/${TC_MUSL_PKG}.tar.gz}"

adm_toolchain_build_binutils_pass1() {
    adm_stage "Cross-toolchain: binutils (passo 1)"

    if [ ! -f "$TC_BINUTILS_TARBALL" ]; then
        adm_die "Tarball do binutils não encontrado: $TC_BINUTILS_TARBALL"
    fi

    adm_toolchain_extract_tarball "$TC_BINUTILS_TARBALL" "$TC_BINUTILS_PKG"
    local srcdir builddir logfile
    srcdir="$(adm_toolchain_source_dir_for "$TC_BINUTILS_PKG")"
    builddir="$ADM_CROSS_BUILD/binutils-pass1"
    logfile="$(adm_toolchain_logfile_for "binutils-pass1")"

    if [ -d "$builddir" ]; then
        rm -rf --one-file-system "$builddir" || adm_die "Falha ao limpar $builddir"
    fi
    adm_ensure_dir "$builddir"

    adm_info "Configurando binutils (pass1) para target=$ADM_TARGET, sysroot=$ADM_CROSS_SYSROOT"

    adm_run_with_spinner "Configurando binutils (pass1)" bash -c "
        cd \"$builddir\" &&
        \"$srcdir/configure\" \
            --target=\"$ADM_TARGET\" \
            --prefix=\"$ADM_CROSS_ROOT/tools\" \
            --with-sysroot=\"$ADM_CROSS_SYSROOT\" \
            --disable-nls \
            --disable-werror \
            >\"$logfile\" 2>&1
    "

    adm_run_with_spinner "Compilando binutils (pass1)" bash -c "
        cd \"$builddir\" &&
        make -j\$(nproc) >>\"$logfile\" 2>&1
    "

    adm_run_with_spinner "Instalando binutils (pass1)" bash -c "
        cd \"$builddir\" &&
        make install >>\"$logfile\" 2>&1
    "

    adm_info "binutils (pass1) instalado em $ADM_CROSS_ROOT/tools"
}

adm_toolchain_build_gcc_pass1() {
    adm_stage "Cross-toolchain: GCC (passo 1)"

    if [ ! -f "$TC_GCC_TARBALL" ]; then
        adm_die "Tarball do GCC não encontrado: $TC_GCC_TARBALL"
    fi

    adm_toolchain_extract_tarball "$TC_GCC_TARBALL" "$TC_GCC_PKG"
    local srcdir builddir logfile
    srcdir="$(adm_toolchain_source_dir_for "$TC_GCC_PKG")"
    builddir="$ADM_CROSS_BUILD/gcc-pass1"
    logfile="$(adm_toolchain_logfile_for "gcc-pass1")"

    if [ -d "$builddir" ]; then
        rm -rf --one-file-system "$builddir" || adm_die "Falha ao limpar $builddir"
    fi
    adm_ensure_dir "$builddir"

    # Ajuste mínimo para não usar headers da libc ainda inexistente
    adm_info "Configurando GCC (pass1) para target=$ADM_TARGET"

    adm_run_with_spinner "Configurando GCC (pass1)" bash -c "
        cd \"$builddir\" &&
        \"$srcdir/configure\" \
            --target=\"$ADM_TARGET\" \
            --prefix=\"$ADM_CROSS_ROOT/tools\" \
            --without-headers \
            --with-newlib \
            --enable-languages=c \
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
            >\"$logfile\" 2>&1
    "

    adm_run_with_spinner "Compilando GCC (pass1)" bash -c "
        cd \"$builddir\" &&
        make all-gcc -j\$(nproc) >>\"$logfile\" 2>&1 &&
        make all-target-libgcc -j\$(nproc) >>\"$logfile\" 2>&1
    "

    adm_run_with_spinner "Instalando GCC (pass1)" bash -c "
        cd \"$builddir\" &&
        make install-gcc >>\"$logfile\" 2>&1 &&
        make install-target-libgcc >>\"$logfile\" 2>&1
    "

    adm_info "GCC (pass1) instalado em $ADM_CROSS_ROOT/tools"
}

adm_toolchain_install_linux_headers() {
    adm_stage "Cross-toolchain: headers do kernel"

    if [ ! -f "$TC_LINUX_TARBALL" ]; then
        adm_die "Tarball do Linux não encontrado: $TC_LINUX_TARBALL"
    fi

    adm_toolchain_extract_tarball "$TC_LINUX_TARBALL" "$TC_LINUX_PKG"
    local srcdir logfile
    srcdir="$(adm_toolchain_source_dir_for "$TC_LINUX_PKG")"
    logfile="$(adm_toolchain_logfile_for "linux-headers")"

    adm_run_with_spinner "Instalando headers do kernel em $ADM_CROSS_SYSROOT/usr" bash -c "
        cd \"$srcdir\" &&
        make mrproper >>\"$logfile\" 2>&1 &&
        make headers >>\"$logfile\" 2>&1 &&
        find include -name '.*' -delete &&
        rm -f include/Makefile &&
        mkdir -p \"$ADM_CROSS_SYSROOT/usr\" &&
        cp -rv include \"$ADM_CROSS_SYSROOT/usr\" >>\"$logfile\" 2>&1
    "
}

adm_toolchain_build_libc_initial_glibc() {
    adm_stage "Cross-toolchain: glibc inicial"

    if [ ! -f "$TC_GLIBC_TARBALL" ]; then
        adm_die "Tarball da glibc não encontrado: $TC_GLIBC_TARBALL"
    fi

    adm_toolchain_extract_tarball "$TC_GLIBC_TARBALL" "$TC_GLIBC_PKG"
    local srcdir builddir logfile
    srcdir="$(adm_toolchain_source_dir_for "$TC_GLIBC_PKG")"
    builddir="$ADM_CROSS_BUILD/glibc-initial"
    logfile="$(adm_toolchain_logfile_for "glibc-initial")"

    if [ -d "$builddir" ]; then
        rm -rf --one-file-system "$builddir" || adm_die "Falha ao limpar $builddir"
    fi
    adm_ensure_dir "$builddir"

    adm_run_with_spinner "Configurando glibc inicial" bash -c "
        cd \"$builddir\" &&
        \"$srcdir/configure\" \
            --prefix=/usr \
            --host=\"$ADM_TARGET\" \
            --build=\"$(adm_toolchain_host_triplet)\" \
            --with-headers=\"$ADM_CROSS_SYSROOT/usr/include\" \
            --enable-kernel=4.19 \
            --disable-werror \
            --enable-obsolete-rpc \
            >\"$logfile\" 2>&1
    "

    adm_run_with_spinner "Compilando glibc inicial" bash -c "
        cd \"$builddir\" &&
        make -j\$(nproc) >>\"$logfile\" 2>&1
    "

    adm_run_with_spinner "Instalando glibc inicial no sysroot" bash -c "
        cd \"$builddir\" &&
        make DESTDIR=\"$ADM_CROSS_SYSROOT\" install >>\"$logfile\" 2>&1
    "

    adm_info "glibc inicial instalada em $ADM_CROSS_SYSROOT"
}

adm_toolchain_build_libc_initial_musl() {
    adm_stage "Cross-toolchain: musl inicial"

    if [ ! -f "$TC_MUSL_TARBALL" ]; then
        adm_die "Tarball do musl não encontrado: $TC_MUSL_TARBALL"
    fi

    adm_toolchain_extract_tarball "$TC_MUSL_TARBALL" "$TC_MUSL_PKG"
    local srcdir builddir logfile
    srcdir="$(adm_toolchain_source_dir_for "$TC_MUSL_PKG")"
    builddir="$ADM_CROSS_BUILD/musl-initial"
    logfile="$(adm_toolchain_logfile_for "musl-initial")"

    if [ -d "$builddir" ]; then
        rm -rf --one-file-system "$builddir" || adm_die "Falha ao limpar $builddir"
    fi
    adm_ensure_dir "$builddir"

    adm_run_with_spinner "Compilando musl inicial" bash -c "
        cd \"$srcdir\" &&
        CC=\"$ADM_TARGET-gcc\" ./configure \
            --prefix=/usr \
            --target=\"$ADM_TARGET\" \
            --syslibdir=/lib \
            --disable-shared \
            >\"$logfile\" 2>&1 &&
        make -j\$(nproc) >>\"$logfile\" 2>&1 &&
        make DESTDIR=\"$ADM_CROSS_SYSROOT\" install >>\"$logfile\" 2>&1
    "

    adm_info "musl inicial instalada em $ADM_CROSS_SYSROOT"
}

adm_toolchain_build_libc_initial() {
    case "$ADM_LIBC" in
        glibc)
            adm_toolchain_build_libc_initial_glibc
            ;;
        musl)
            adm_toolchain_build_libc_initial_musl
            ;;
        *)
            adm_die "ADM_LIBC='$ADM_LIBC' não suportada (use glibc ou musl)"
            ;;
    esac
}

adm_toolchain_build_gcc_final() {
    adm_stage "Cross-toolchain: GCC final"

    if [ ! -f "$TC_GCC_TARBALL" ]; then
        adm_die "Tarball do GCC não encontrado: $TC_GCC_TARBALL"
    fi

    # Reusar o source já extraído, mas pode re-extrair se quiser limpeza
    adm_toolchain_extract_tarball "$TC_GCC_TARBALL" "$TC_GCC_PKG"
    local srcdir builddir logfile
    srcdir="$(adm_toolchain_source_dir_for "$TC_GCC_PKG")"
    builddir="$ADM_CROSS_BUILD/gcc-final"
    logfile="$(adm_toolchain_logfile_for 'gcc-final')"

    if [ -d "$builddir" ]; then
        rm -rf --one-file-system "$builddir" || adm_die "Falha ao limpar $builddir"
    fi
    adm_ensure_dir "$builddir"

    adm_run_with_spinner "Configurando GCC final" bash -c "
        cd \"$builddir\" &&
        \"$srcdir/configure\" \
            --target=\"$ADM_TARGET\" \
            --prefix=\"$ADM_CROSS_ROOT/tools\" \
            --with-sysroot=\"$ADM_CROSS_SYSROOT\" \
            --enable-languages=c,c++ \
            --disable-multilib \
            --disable-nls \
            --disable-libsanitizer \
            >\"$logfile\" 2>&1
    "

    adm_run_with_spinner "Compilando GCC final" bash -c "
        cd \"$builddir\" &&
        make -j\$(nproc) >>\"$logfile\" 2>&1
    "

    adm_run_with_spinner "Instalando GCC final" bash -c "
        cd \"$builddir\" &&
        make install >>\"$logfile\" 2>&1
    "

    adm_info "GCC final do cross instalado em $ADM_CROSS_ROOT/tools"
}

adm_toolchain_build_cross_all() {
    adm_stage "Stage 1 - Construção do cross-toolchain"
    adm_toolchain_init_paths
    adm_toolchain_check_host_prereqs

    adm_toolchain_build_binutils_pass1
    adm_toolchain_build_gcc_pass1
    adm_toolchain_install_linux_headers
    adm_toolchain_build_libc_initial
    adm_toolchain_build_gcc_final

    adm_info "Cross-toolchain completo em $ADM_CROSS_ROOT (sysroot: $ADM_CROSS_SYSROOT)"
}

# ----------------------------------------------------------------------
# Temporary tools (stage1) usando o cross-toolchain
# ----------------------------------------------------------------------
# Aqui a ideia é usar o cross-toolchain recém construído e instalar
# ferramentas básicas em ADM_ROOTFS_STAGE1. Para não duplicar lógica
# de build de pacotes, tentamos delegar para uma função de alto nível
# (ex: 31-build-engine.sh), mas se ela não existir, abortamos com
# mensagem clara (nada silencioso).

adm_toolchain_stage1_env_for_temp_tools() {
    # Ajusta ambiente para usar o cross-toolchain
    export PATH="$ADM_CROSS_ROOT/tools/bin:$PATH"
    export CC="${ADM_TARGET}-gcc"
    export CXX="${ADM_TARGET}-g++"
    export AR="${ADM_TARGET}-ar"
    export RANLIB="${ADM_TARGET}-ranlib"
    export LD="${ADM_TARGET}-ld"

    # sysroot:
    export SYSROOT="$ADM_CROSS_SYSROOT"
}

adm_toolchain_stage1_build_temp_tool() {
    # Contrói uma ferramenta temporária usando mecanismo genérico, se existir.
    #
    # Uso:
    #   adm_toolchain_stage1_build_temp_tool categoria nome
    #
    local category="${1:-}"
    local name="${2:-}"

    [ -z "$category" ] && adm_die "adm_toolchain_stage1_build_temp_tool requer categoria"
    [ -z "$name" ]     && adm_die "adm_toolchain_stage1_build_temp_tool requer nome"

    # Se o build-engine estiver disponível:
    if declare -F adm_build_pkg >/dev/null 2>&1; then
        # Convenção: adm_build_pkg categoria nome modo destdir
        # modo para stage1: "stage1"
        local destdir="$ADM_ROOTFS_STAGE1"
        adm_info "Construindo temporary tool (stage1) $category/$name para destdir=$destdir"
        adm_build_pkg "$category" "$name" "stage1" "$destdir"
    elif declare -F adm_build_engine_build >/dev/null 2>&1; then
        # Alternativa: uma função mais específica do build-engine
        local destdir="$ADM_ROOTFS_STAGE1"
        adm_info "Construindo temporary tool (stage1) $category/$name (via adm_build_engine_build)"
        adm_build_engine_build "$category" "$name" "stage1" "$destdir"
    else
        adm_die "Nenhum mecanismo de build de pacotes disponível (adm_build_pkg / adm_build_engine_build) para construir '$category/$name'. Integre com 31-build-engine.sh."
    fi
}

adm_toolchain_stage1_build_temp_tools_list() {
    # Lista de temporary tools recomendadas para stage1.
    # Você pode ajustar categorias/nome para combinar com seu repo.
    cat <<EOF
sys m4
sys ncurses
sys bash
sys coreutils
sys diffutils
sys findutils
sys gawk
sys grep
sys gzip
sys m4
sys make
sys patch
sys sed
sys tar
sys xz
sys file
EOF
}

adm_toolchain_build_temp_tools_stage1() {
    adm_stage "Stage 2 - Temporary tools (stage1)"

    adm_toolchain_init_paths
    adm_toolchain_stage1_env_for_temp_tools

    adm_ensure_dir "$ADM_ROOTFS_STAGE1"

    # Cria layout básico do rootfs-stage1
    adm_ensure_dir "$ADM_ROOTFS_STAGE1/tools"
    adm_ensure_dir "$ADM_ROOTFS_STAGE1/usr"
    adm_ensure_dir "$ADM_ROOTFS_STAGE1/bin"
    adm_ensure_dir "$ADM_ROOTFS_STAGE1/lib"
    adm_ensure_dir "$ADM_ROOTFS_STAGE1/etc"
    adm_ensure_dir "$ADM_ROOTFS_STAGE1/var"
    adm_ensure_dir "$ADM_ROOTFS_STAGE1/tmp"

    chmod 1777 "$ADM_ROOTFS_STAGE1/tmp" || adm_die "Falha ao ajustar permissão de $ADM_ROOTFS_STAGE1/tmp"

    local line category name
    while IFS= read -r line || [ -n "$line" ]; do
        # Ignora linhas vazias/comentários
        case "$line" in
            ''|'#'*) continue ;;
        esac
        category="${line%% *}"
        name="${line#* }"
        adm_toolchain_stage1_build_temp_tool "$category" "$name"
    done < <(adm_toolchain_stage1_build_temp_tools_list)

    adm_info "Temporary tools (stage1) instaladas em $ADM_ROOTFS_STAGE1"
}

adm_toolchain_stage1_build_all() {
    adm_toolchain_build_cross_all
    adm_toolchain_build_temp_tools_stage1
    adm_info "Toolchain cross + temporary tools stage1 concluídos."
}

# ----------------------------------------------------------------------
# CLI quando executado diretamente
# ----------------------------------------------------------------------

adm_toolchain_usage() {
    cat <<EOF
Uso: $(basename "$0") <comando>

Comandos:
  cross      - Construir apenas o cross-toolchain (binutils/gcc/libc...)
  stage1     - Construir apenas temporary tools (stage1) usando cross já existente
  all        - Construir cross-toolchain + temporary tools (stage1)
  help       - Mostrar esta ajuda

Exemplos:
  $(basename "$0") cross
  $(basename "$0") stage1
  $(basename "$0") all
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-help}"
    case "$cmd" in
        cross)
            adm_toolchain_build_cross_all
            ;;
        stage1)
            adm_toolchain_build_temp_tools_stage1
            ;;
        all)
            adm_toolchain_stage1_build_all
            ;;
        help|-h|--help)
            adm_toolchain_usage
            ;;
        *)
            adm_error "Comando desconhecido: $cmd"
            adm_toolchain_usage
            exit 1
            ;;
    esac
fi
