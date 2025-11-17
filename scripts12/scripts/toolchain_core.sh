#!/usr/bin/env bash
# toolchain_core.sh – inteligência central do toolchain (modelo híbrido)

ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_TC_ROOT="${ADM_TC_ROOT:-$ADM_ROOT/cross}"

# Lê campos especiais do metafile, se existirem
# Espera MF_TC_ROLE, MF_TC_STAGE, MF_CATEGORY, MF_NAME, MF_VERSION carregados pelo metafile.sh
tc_core_normalize_meta() {
    : "${MF_CATEGORY:=unknown}"
    : "${MF_NAME:=unknown}"
    : "${MF_VERSION:=0}"
    : "${MF_TC_ROLE:=auto}"
    : "${MF_TC_STAGE:=auto}"
}

# Detecta target padrão
tc_core_detect_target() {
    if [ -n "$ADM_TC_TARGET" ]; then
        printf '%s\n' "$ADM_TC_TARGET"
        return 0
    fi
    if command -v gcc >/dev/null 2>&1; then
        gcc -dumpmachine 2>/dev/null && return 0
    fi
    printf '%s\n' "x86_64-unknown-linux-gnu"
}

# Detecta modo (cross x native)
tc_core_detect_mode() {
    # Respeita override
    if [ -n "$ADM_TC_MODE" ]; then
        printf '%s\n' "$ADM_TC_MODE"
        return 0
    fi

    case "$MF_TC_ROLE" in
        cross-*|cross)
            printf 'cross\n'
            return 0
            ;;
    esac

    # heurística por caminho/target
    if [ -n "$ADM_TC_TARGET" ] && [ -n "$ADM_TC_PREFIX" ]; then
        case "$ADM_TC_PREFIX" in
            "$ADM_TC_ROOT"/*)
                printf 'cross\n'
                return 0
                ;;
        esac
    fi

    printf 'native\n'
}

# Decide estágio de build global (ADM_BUILD_STAGE)
tc_core_detect_stage() {
    if [ -n "$ADM_BUILD_STAGE" ]; then
        printf '%s\n' "$ADM_BUILD_STAGE"
        return 0
    fi

    case "$MF_TC_STAGE" in
        auto|"")
            # heurística por pacote
            case "$MF_NAME" in
                binutils-pass1|binutils-cross-pass1|binutils-stage1)
                    printf 'cross-pass1\n' ;;
                gcc-pass1|gcc-cross-pass1|gcc-stage1)
                    printf 'cross-pass1\n' ;;
                glibc-cross|musl-cross)
                    printf 'cross-glibc\n' ;;
                libstdcxx-pass1|libstdcxx-cross)
                    printf 'cross-libstdcxx\n' ;;
                m4-temp|ncurses-temp|bash-temp|coreutils-temp|*-temp)
                    printf 'cross-temp-tools\n' ;;
                binutils-pass2|binutils-cross-pass2)
                    printf 'cross-pass2\n' ;;
                gcc-pass2|gcc-cross-pass2)
                    printf 'cross-pass2\n' ;;
                *)
                    printf 'final-system\n' ;;
            esac
            ;;
        *)
            printf '%s\n' "$MF_TC_STAGE"
            ;;
    esac
}

# Calcula prefix/destdir inteligentes
tc_core_resolve_paths() {
    local target="$1" stage="$2" mode="$3"

    if [ "$mode" = "cross" ]; then
        local base="$ADM_TC_ROOT/$target"
        case "$stage" in
            cross-pass1|cross-glibc|cross-libstdcxx)
                ADM_TC_PREFIX="$base/tools"
                ADM_TC_ROOTFS="$base/rootfs"
                DESTDIR="$ADM_TC_PREFIX"   # só toolchain em /tools
                ;;
            cross-temp-tools|cross-pass2)
                ADM_TC_PREFIX="$base/rootfs/usr"
                ADM_TC_ROOTFS="$base/rootfs"
                DESTDIR="$ADM_TC_ROOTFS"   # rootfs completo
                ;;
            *)
                ADM_TC_PREFIX="$base/rootfs/usr"
                ADM_TC_ROOTFS="$base/rootfs"
                DESTDIR="$ADM_TC_ROOTFS"
                ;;
        esac
    else
        # modo nativo (toolchain final)
        ADM_TC_PREFIX="/usr"
        ADM_TC_ROOTFS="/"
        DESTDIR="$ADM_ROOT/destdir/$MF_NAME-$MF_VERSION"
    fi

    export ADM_TC_PREFIX ADM_TC_ROOTFS DESTDIR
}

# Exporta variáveis de ambiente para o build_core/source/instalador
tc_core_apply_env() {
    tc_core_normalize_meta

    local target mode stage
    target="$(tc_core_detect_target)"
    mode="$(tc_core_detect_mode)"
    stage="$(tc_core_detect_stage)"

    export ADM_TC_TARGET="$target"
    export ADM_TC_MODE="$mode"
    export ADM_BUILD_STAGE="$stage"

    tc_core_resolve_paths "$target" "$stage" "$mode"

    # toolchain cross: ajusta toolchain padrão
    if [ "$mode" = "cross" ]; then
        export CC="${CC:-$target-gcc}"
        export CXX="${CXX:-$target-g++}"
        export AR="${AR:-$target-ar}"
        export RANLIB="${RANLIB:-$target-ranlib}"
        export LD="${LD:-$target-ld}"
    fi
}
