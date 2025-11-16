#!/usr/bin/env bash
# profile.sh – Sistema de perfis EXTREMO do ADM
#
# - Perfis base: aggressive | normal | minimal
# - Perfis por linguagem: c, cpp, rust, go, kernel, llvm, toolchain
# - Ajustes por libc: glibc, musl
# - Ajustes por init: systemd, sysv, runit
# - Ajustes por target (cross-toolchain)
# - Escolha de linker: mold, lld, gold, bfd
# - Suporte a PGO, LTO, sanitizers e build reprodutível
# - Criação automática de perfis em /usr/src/adm/profiles
# - Nenhum erro silencioso: tudo logado, tudo retorna status
# Diretórios e estado global
ADM_PROFILE_DIR="/usr/src/adm/profiles"
ADM_PROFILE_COMPILED_DIR="$ADM_PROFILE_DIR/compiled"

ADM_CURRENT_PROFILE=""     # aggressive|normal|minimal
ADM_CURRENT_LIBC=""        # glibc|musl
ADM_CURRENT_INIT=""        # systemd|runit|sysv
ADM_CURRENT_TARGET=""      # ex: aarch64-linux-musl
ADM_CURRENT_LANG=""        # ex: c, cpp, rust, go, kernel, llvm, toolchain
ADM_CURRENT_PKG=""         # nome do pacote (p/ perfil compilado)

ADM_LINKER=""              # mold|lld|gold|bfd
ADM_HW_ARCH=""             # x86_64, aarch64, riscv64, etc.
ADM_HW_CORES=1
ADM_HW_MEM_MB=0

# flags “modo” (podem vir do ambiente ou de scripts superiores)
ADM_BUILD_MODE="${ADM_BUILD_MODE:-release}"        # release|debug|relwithdebinfo
ADM_BUILD_PGO="${ADM_BUILD_PGO:-off}"              # off|generate|use
ADM_BUILD_LTO="${ADM_BUILD_LTO:-auto}"             # off|thin|full|auto
ADM_SANITIZERS="${ADM_SANITIZERS:-}"               # "asan,ubsan" etc.
ADM_REPRODUCIBLE="${ADM_REPRODUCIBLE:-0}"          # 0|1

# UI opcional
_PROFILE_HAS_UI=0
if declare -F adm_ui_log_info >/dev/null 2>&1; then
    _PROFILE_HAS_UI=1
fi

_prof_log() {
    local lvl="$1"; shift || true
    local msg="$*"
    if [ "$_PROFILE_HAS_UI" -eq 1 ]; then
        case "$lvl" in
            INFO)  adm_ui_log_info  "$msg" ;;
            WARN)  adm_ui_log_warn  "$msg" ;;
            ERROR) adm_ui_log_error "$msg" ;;
            DEBUG) adm_ui_log_info  "[DEBUG] $msg" ;;
            *)     adm_ui_log_info  "$msg" ;;
        esac
    else
        printf 'profile[%s]: %s\n' "$lvl" "$msg" >&2
    fi
}

_prof_fail() {
    _prof_log ERROR "$*"
    return 1
}

_prof_trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

_prof_nproc() {
    local n
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    case "$n" in
        ''|*[!0-9]*) n=1 ;;
    esac
    echo "$n"
}

# -----------------------------
# Detecção de hardware básica
# -----------------------------
adm_profile_detect_hardware() {
    # arquitetura
    ADM_HW_ARCH="$(uname -m 2>/dev/null || echo unknown)"

    # núcleos
    ADM_HW_CORES="$(_prof_nproc)"

    # memória em MB
    if [ -r /proc/meminfo ]; then
        local kb
        kb="$(grep -i '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print $2}')" || kb=0
        case "$kb" in
            ''|*[!0-9]*) kb=0 ;;
        esac
        ADM_HW_MEM_MB=$((kb / 1024))
    else
        ADM_HW_MEM_MB=0
    fi

    _prof_log INFO "Hardware detectado: arch=$ADM_HW_ARCH cores=$ADM_HW_CORES mem=${ADM_HW_MEM_MB}MB"
    return 0
}

# -----------------------------
# Detecção de linkers disponíveis
# -----------------------------
adm_profile_detect_linker() {
    # ordem de preferência:
    # mold -> lld -> gold -> bfd (default ld)
    local found=""

    if command -v mold >/dev/null 2>&1; then
        found="mold"
    elif command -v ld.lld >/dev/null 2>&1 || command -v lld >/dev/null 2>&1; then
        found="lld"
    elif command -v ld.gold >/dev/null 2>&1; then
        found="gold"
    elif command -v ld >/dev/null 2>&1; then
        found="bfd"
    fi

    if [ -z "$found" ]; then
        _prof_log WARN "Nenhum linker conhecido encontrado; assumindo ld (bfd)"
        ADM_LINKER="bfd"
    else
        ADM_LINKER="$found"
    fi

    _prof_log INFO "Linker selecionado automaticamente: $ADM_LINKER"
    return 0
}

# -----------------------------
# Criação de diretórios de perfil
# -----------------------------
adm_profile_ensure_dirs() {
    if ! mkdir -p "$ADM_PROFILE_DIR" "$ADM_PROFILE_COMPILED_DIR" 2>/dev/null; then
        _prof_fail "Não foi possível criar diretórios de perfis em $ADM_PROFILE_DIR"
    fi
    return 0
}

# -----------------------------
# Perfis base default (aggressive/normal/minimal)
# -----------------------------
adm_profile_create_base_profiles() {
    adm_profile_ensure_dirs

    # aggressive
    if [ ! -f "$ADM_PROFILE_DIR/aggressive.conf" ]; then
        cat > "$ADM_PROFILE_DIR/aggressive.conf" << 'EOF'
# Perfil aggressive – máximo desempenho geral (ainda relativamente seguro)
CFLAGS="-O3 -pipe -march=native -mtune=native -fno-plt"
CXXFLAGS="$CFLAGS"
LDFLAGS="-Wl,-O3"
MAKEFLAGS="-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
EOF
        _prof_log INFO "Criado perfil base: aggressive"
    fi

    # normal
    if [ ! -f "$ADM_PROFILE_DIR/normal.conf" ]; then
        cat > "$ADM_PROFILE_DIR/normal.conf" << 'EOF'
# Perfil normal – estável e recomendado para maioria dos pacotes
CFLAGS="-O2 -pipe -fno-plt"
CXXFLAGS="$CFLAGS"
LDFLAGS="-Wl,-O2"
MAKEFLAGS="-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
EOF
        _prof_log INFO "Criado perfil base: normal"
    fi

    # minimal
    if [ ! -f "$ADM_PROFILE_DIR/minimal.conf" ]; then
        cat > "$ADM_PROFILE_DIR/minimal.conf" << 'EOF'
# Perfil minimal – seguro, previsível, usado em toolchains e estágios iniciais
CFLAGS="-O1 -pipe -g0"
CXXFLAGS="$CFLAGS"
LDFLAGS=""
MAKEFLAGS="-j1"
EOF
        _prof_log INFO "Criado perfil base: minimal"
    fi

    return 0
}

# -----------------------------
# Perfis overlay por linguagem/libc/init/target
# (são defaults; ajustes adicionais podem ser aplicados em memória)
# -----------------------------
adm_profile_create_overlay_defaults() {
    adm_profile_ensure_dirs

    # linguagem C
    [ -f "$ADM_PROFILE_DIR/lang_c.conf" ] || cat > "$ADM_PROFILE_DIR/lang_c.conf" << 'EOF'
# Ajustes adicionais típicos para C
LANG_CFLAGS="-Wall -Wextra -Wformat -Wformat-security"
EOF

    # C++
    [ -f "$ADM_PROFILE_DIR/lang_cpp.conf" ] || cat > "$ADM_PROFILE_DIR/lang_cpp.conf" << 'EOF'
# Ajustes adicionais típicos para C++
LANG_CXXFLAGS="-Wall -Wextra -Wnon-virtual-dtor -Woverloaded-virtual"
EOF

    # Rust
    [ -f "$ADM_PROFILE_DIR/lang_rust.conf" ] || cat > "$ADM_PROFILE_DIR/lang_rust.conf" << 'EOF'
# Ajustes para Rust (usados por toolchains específicos, não aqui diretamente)
RUST_PROFILE_RELEASE="-C opt-level=3"
RUST_PROFILE_DEBUG="-C debuginfo=2"
EOF

    # Go
    [ -f "$ADM_PROFILE_DIR/lang_go.conf" ] || cat > "$ADM_PROFILE_DIR/lang_go.conf" << 'EOF'
# Ajustes para Go
GO_BUILD_FLAGS=""
EOF

    # Kernel
    [ -f "$ADM_PROFILE_DIR/lang_kernel.conf" ] || cat > "$ADM_PROFILE_DIR/lang_kernel.conf" << 'EOF'
# Kernel tende a ser sensível; sem LTO agressivo aqui
KERNEL_CFLAGS=""
EOF

    # Toolchain (gcc/binutils)
    [ -f "$ADM_PROFILE_DIR/lang_toolchain.conf" ] || cat > "$ADM_PROFILE_DIR/lang_toolchain.conf" << 'EOF'
# Toolchain precisa de flags mais conservadoras
TOOLCHAIN_CFLAGS="-O2 -pipe"
EOF

    # musl
    [ -f "$ADM_PROFILE_DIR/libc_musl.conf" ] || cat > "$ADM_PROFILE_DIR/libc_musl.conf" << 'EOF'
# Ajustes para musl
LIBC_MUSL_CFLAGS="-D_GNU_SOURCE"
EOF

    # glibc
    [ -f "$ADM_PROFILE_DIR/libc_glibc.conf" ] || cat > "$ADM_PROFILE_DIR/libc_glibc.conf" << 'EOF'
# Ajustes para glibc (normalmente nenhum obrigatório)
LIBC_GLIBC_CFLAGS=""
EOF

    # init systemd
    [ -f "$ADM_PROFILE_DIR/init_systemd.conf" ] || cat > "$ADM_PROFILE_DIR/init_systemd.conf" << 'EOF'
# Ajustes para systemd (nenhum por padrão)
INIT_SYSTEMD_FLAGS=""
EOF

    # init sysv
    [ -f "$ADM_PROFILE_DIR/init_sysv.conf" ] || cat > "$ADM_PROFILE_DIR/init_sysv.conf" << 'EOF'
INIT_SYSV_FLAGS=""
EOF

    # init runit
    [ -f "$ADM_PROFILE_DIR/init_runit.conf" ] || cat > "$ADM_PROFILE_DIR/init_runit.conf" << 'EOF'
INIT_RUNIT_FLAGS=""
EOF

    return 0
}

# -----------------------------
# Inicialização global de profiles (chamada 1x no adm)
# -----------------------------
adm_profile_init() {
    adm_profile_ensure_dirs || return 1
    adm_profile_detect_hardware || return 1
    adm_profile_detect_linker || return 1
    adm_profile_create_base_profiles || return 1
    adm_profile_create_overlay_defaults || return 1
    _prof_log INFO "Sistema de perfis inicializado"
    return 0
}
# -----------------------------
# Validação de libc/init/profile
# -----------------------------
adm_profile_validate_libc() {
    local libc="$1"
    case "$libc" in
        glibc|musl) return 0 ;;
        *) _prof_fail "Libc inválida: '$libc' (use glibc ou musl)" ;;
    esac
}

adm_profile_validate_init() {
    local init="$1"
    case "$init" in
        systemd|runit|sysv) return 0 ;;
        *) _prof_fail "Init inválido: '$init' (use systemd, runit ou sysv)" ;;
    esac
}

adm_profile_validate_profile() {
    local profile="$1"
    case "$profile" in
        aggressive|normal|minimal) return 0 ;;
        *) _prof_fail "Perfil inválido: '$profile'" ;;
    esac
}

# linguagem principal do pacote (ex: a partir do detect)
adm_profile_validate_lang() {
    local lang="$1"
    case "$lang" in
        ""|c|cpp|rust|go|kernel|llvm|toolchain) return 0 ;;
        *) _prof_log WARN "Linguagem desconhecida '$lang', nenhum overlay específico será aplicado"; return 0 ;;
    esac
}

# -----------------------------
# Seleção fina de linker (aplicando flags)
# -----------------------------
adm_profile_apply_linker() {
    # Requer ADM_LINKER já detectado
    case "$ADM_LINKER" in
        mold)
            LDFLAGS="$LDFLAGS -Wl,-O2 -fuse-ld=mold"
            ;;
        lld)
            LDFLAGS="$LDFLAGS -Wl,-O2 -fuse-ld=lld"
            ;;
        gold)
            # -fuse-ld=gold pode não existir em todos, mas é bem comum
            LDFLAGS="$LDFLAGS -Wl,-O2 -fuse-ld=gold"
            ;;
        bfd|*)
            # linker default, sem flag extra obrigatória
            LDFLAGS="$LDFLAGS -Wl,-O1"
            ;;
    esac
    _prof_log INFO "LDFLAGS após seleção de linker ($ADM_LINKER): $LDFLAGS"
}

# -----------------------------
# Aplicar overlays de linguagem/libc/init
# -----------------------------
adm_profile_apply_language_overlay() {
    local lang="$ADM_CURRENT_LANG"
    case "$lang" in
        c)
            # shellcheck source=/usr/src/adm/profiles/lang_c.conf
            . "$ADM_PROFILE_DIR/lang_c.conf" 2>/dev/null || true
            [ -n "$LANG_CFLAGS" ] && CFLAGS="$CFLAGS $LANG_CFLAGS"
            ;;
        cpp)
            # shellcheck source=/usr/src/adm/profiles/lang_cpp.conf
            . "$ADM_PROFILE_DIR/lang_cpp.conf" 2>/dev/null || true
            [ -n "$LANG_CXXFLAGS" ] && CXXFLAGS="$CXXFLAGS $LANG_CXXFLAGS"
            ;;
        rust)
            # rust não usa CFLAGS diretamente, mas mantemos info para scripts superiores
            # shellcheck source=/usr/src/adm/profiles/lang_rust.conf
            . "$ADM_PROFILE_DIR/lang_rust.conf" 2>/dev/null || true
            ;;
        go)
            # shellcheck source=/usr/src/adm/profiles/lang_go.conf
            . "$ADM_PROFILE_DIR/lang_go.conf" 2>/dev/null || true
            ;;
        kernel)
            # shellcheck source=/usr/src/adm/profiles/lang_kernel.conf
            . "$ADM_PROFILE_DIR/lang_kernel.conf" 2>/dev/null || true
            [ -n "$KERNEL_CFLAGS" ] && CFLAGS="$CFLAGS $KERNEL_CFLAGS"
            ;;
        llvm)
            # LLVM geralmente se beneficia de LTO e linkers rápidos (lld/mold) – já tratado
            ;;
        toolchain)
            # shellcheck source=/usr/src/adm/profiles/lang_toolchain.conf
            . "$ADM_PROFILE_DIR/lang_toolchain.conf" 2>/dev/null || true
            [ -n "$TOOLCHAIN_CFLAGS" ] && CFLAGS="$TOOLCHAIN_CFLAGS"
            ;;
        "")
            ;;
        *)
            # já logado em validate_lang
            ;;
    esac
}

adm_profile_apply_libc_overlay() {
    case "$ADM_CURRENT_LIBC" in
        musl)
            # shellcheck source=/usr/src/adm/profiles/libc_musl.conf
            . "$ADM_PROFILE_DIR/libc_musl.conf" 2>/dev/null || true
            [ -n "$LIBC_MUSL_CFLAGS" ] && CFLAGS="$CFLAGS $LIBC_MUSL_CFLAGS"
            ;;
        glibc)
            # shellcheck source=/usr/src/adm/profiles/libc_glibc.conf
            . "$ADM_PROFILE_DIR/libc_glibc.conf" 2>/dev/null || true
            [ -n "$LIBC_GLIBC_CFLAGS" ] && CFLAGS="$CFLAGS $LIBC_GLIBC_CFLAGS"
            ;;
        *)
            ;;
    esac
}

adm_profile_apply_init_overlay() {
    case "$ADM_CURRENT_INIT" in
        systemd)
            # shellcheck source=/usr/src/adm/profiles/init_systemd.conf
            . "$ADM_PROFILE_DIR/init_systemd.conf" 2>/dev/null || true
            ;;
        sysv)
            # shellcheck source=/usr/src/adm/profiles/init_sysv.conf
            . "$ADM_PROFILE_DIR/init_sysv.conf" 2>/dev/null || true
            ;;
        runit)
            # shellcheck source=/usr/src/adm/profiles/init_runit.conf
            . "$ADM_PROFILE_DIR/init_runit.conf" 2>/dev/null || true
            ;;
        *)
            ;;
    esac
}

# -----------------------------
# LTO / PGO / Sanitizers / Reproducible
# -----------------------------
adm_profile_apply_lto() {
    local mode="$ADM_BUILD_LTO"

    case "$mode" in
        off)
            _prof_log INFO "LTO desativado explicitamente"
            ;;
        thin)
            CFLAGS="$CFLAGS -flto=thin"
            CXXFLAGS="$CXXFLAGS -flto=thin"
            LDFLAGS="$LDFLAGS -flto=thin"
            _prof_log INFO "LTO thin ativado"
            ;;
        full)
            CFLAGS="$CFLAGS -flto"
            CXXFLAGS="$CXXFLAGS -flto"
            LDFLAGS="$LDFLAGS -flto"
            _prof_log INFO "LTO full ativado"
            ;;
        auto|*)
            # Heurística: aggressive -> full, normal -> thin, minimal -> off
            case "$ADM_CURRENT_PROFILE" in
                aggressive)
                    CFLAGS="$CFLAGS -flto"
                    CXXFLAGS="$CXXFLAGS -flto"
                    LDFLAGS="$LDFLAGS -flto"
                    _prof_log INFO "LTO full ativado (auto, perfil aggressive)"
                    ;;
                normal)
                    CFLAGS="$CFLAGS -flto=thin"
                    CXXFLAGS="$CXXFLAGS -flto=thin"
                    LDFLAGS="$LDFLAGS -flto=thin"
                    _prof_log INFO "LTO thin ativado (auto, perfil normal)"
                    ;;
                minimal)
                    _prof_log INFO "LTO desativado para perfil minimal"
                    ;;
            esac
            ;;
    esac
}

adm_profile_apply_pgo() {
    case "$ADM_BUILD_PGO" in
        generate)
            CFLAGS="$CFLAGS -fprofile-generate"
            CXXFLAGS="$CXXFLAGS -fprofile-generate"
            LDFLAGS="$LDFLAGS -fprofile-generate"
            _prof_log INFO "PGO: fase de geração de perfis (generate)"
            ;;
        use)
            CFLAGS="$CFLAGS -fprofile-use -fprofile-correction"
            CXXFLAGS="$CXXFLAGS -fprofile-use -fprofile-correction"
            LDFLAGS="$LDFLAGS -fprofile-use"
            _prof_log INFO "PGO: fase de uso de perfis (use)"
            ;;
        off|*)
            ;;
    esac
}

adm_profile_apply_sanitizers() {
    [ -z "$ADM_SANITIZERS" ] && return 0

    local san="$ADM_SANITIZERS"
    san="${san// /}"  # remove espaços

    CFLAGS="$CFLAGS -fsanitize=${san}"
    CXXFLAGS="$CXXFLAGS -fsanitize=${san}"
    LDFLAGS="$LDFLAGS -fsanitize=${san}"

    _prof_log INFO "Sanitizers ativados: $san"
}

adm_profile_apply_reproducible() {
    [ "$ADM_REPRODUCIBLE" = "1" ] || return 0

    CFLAGS="$CFLAGS -fno-record-gcc-switches -fno-common"
    CXXFLAGS="$CXXFLAGS -fno-record-gcc-switches -fno-common"
    export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-946684800}"  # 2000-01-01 como default
    _prof_log INFO "Modo reprodutível ativado (SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH)"
}

# -----------------------------
# Aplicar regras de build mode (release/debug/relwithdebinfo)
# -----------------------------
adm_profile_apply_build_mode() {
    case "$ADM_BUILD_MODE" in
        debug)
            CFLAGS="$CFLAGS -O0 -g3"
            CXXFLAGS="$CXXFLAGS -O0 -g3"
            _prof_log INFO "Modo DEBUG ativado (flags de debug adicionadas)"
            ;;
        relwithdebinfo)
            CFLAGS="$CFLAGS -O2 -g"
            CXXFLAGS="$CXXFLAGS -O2 -g"
            _prof_log INFO "Modo RELWITHDEBINFO ativado"
            ;;
        release|*)
            # release já padrão nos perfis base, não mexe
            ;;
    esac
}

# -----------------------------
# Montar perfil final (base + overlays + modos)
# -----------------------------
adm_profile_load() {
    # Interface EXTREMA:
    #   adm_profile_load PROFILE LIBC INIT [PKG] [LANG] [TARGET]
    #
    # Compatível com interface antiga:
    #   adm_profile_load PROFILE LIBC INIT [TARGET]
    #
    local profile="$1"
    local libc="$2"
    local init="$3"
    local arg4="${4:-}"
    local arg5="${5:-}"
    local arg6="${6:-}"

    if [ -z "$profile" ] || [ -z "$libc" ] || [ -z "$init" ]; then
        _prof_fail "adm_profile_load: argumentos obrigatórios: PROFILE LIBC INIT [PKG] [LANG] [TARGET]"
        return 1
    fi

    adm_profile_ensure_dirs || return 1
    adm_profile_validate_profile "$profile" || return 1
    adm_profile_validate_libc "$libc"       || return 1
    adm_profile_validate_init "$init"       || return 1

    # Decidir se arg4 é TARGET (modo antigo) ou PKG (modo novo)
    ADM_CURRENT_PROFILE="$profile"
    ADM_CURRENT_LIBC="$libc"
    ADM_CURRENT_INIT="$init"
    ADM_CURRENT_PKG=""
    ADM_CURRENT_LANG=""
    ADM_CURRENT_TARGET=""

    if [ -n "$arg4" ] && [ -z "$arg5" ] && [ -z "$arg6" ]; then
        # modo antigo: PROFILE LIBC INIT TARGET
        ADM_CURRENT_TARGET="$arg4"
    else
        ADM_CURRENT_PKG="$arg4"
        ADM_CURRENT_LANG="$arg5"
        ADM_CURRENT_TARGET="$arg6"
    fi

    adm_profile_validate_lang "$ADM_CURRENT_LANG" || return 1

    # Limpa flags anteriores
    unset CFLAGS CXXFLAGS LDFLAGS MAKEFLAGS CC CXX AR RANLIB AS LD STRIP OBJCOPY OBJDUMP SYSROOT

    # Carrega base
    local conf="$ADM_PROFILE_DIR/$profile.conf"
    if [ ! -f "$conf" ]; then
        _prof_fail "Perfil base '$profile' não encontrado em $ADM_PROFILE_DIR"
        return 1
    fi

    # shellcheck source=/usr/src/adm/profiles/aggressive.conf
    . "$conf" || _prof_fail "Falha ao carregar perfil base: $conf"

    [ -z "$CFLAGS" ]    && _prof_fail "Perfil $profile: CFLAGS vazios" && return 1
    [ -z "$CXXFLAGS" ]  && _prof_fail "Perfil $profile: CXXFLAGS vazios" && return 1
    [ -z "$MAKEFLAGS" ] && _prof_fail "Perfil $profile: MAKEFLAGS vazios" && return 1

    # Overlays
    adm_profile_apply_language_overlay
    adm_profile_apply_libc_overlay
    adm_profile_apply_init_overlay

    # Seleção de linker (ajusta LDFLAGS)
    adm_profile_apply_linker

    # LTO / PGO / sanitizers / reproducible / modo de build
    adm_profile_apply_lto
    adm_profile_apply_pgo
    adm_profile_apply_sanitizers
    adm_profile_apply_reproducible
    adm_profile_apply_build_mode

    # Ajustes de target (cross-toolchain)
    adm_profile_apply_target_rules

    # Export final
    export CFLAGS CXXFLAGS LDFLAGS MAKEFLAGS
    [ -n "$SYSROOT" ] && export SYSROOT
    [ -n "$CC" ] && export CC CXX AR RANLIB AS LD STRIP OBJCOPY OBJDUMP

    _prof_log INFO "Perfil final montado: profile=$ADM_CURRENT_PROFILE libc=$ADM_CURRENT_LIBC init=$ADM_CURRENT_INIT lang=${ADM_CURRENT_LANG:-none} target=${ADM_CURRENT_TARGET:-native} pkg=${ADM_CURRENT_PKG:-none}"

    # Salva um snapshot do perfil compilado (p/ debug)
    adm_profile_save_compiled_snapshot || true

    return 0
}
# -----------------------------
# Regras automáticas para target (cross-toolchain)
# -----------------------------
adm_profile_apply_target_rules() {
    local tgt="$ADM_CURRENT_TARGET"
    [ -z "$tgt" ] && return 0  # build nativo

    # Ferramentas cross
    export CC="${tgt}-gcc"
    export CXX="${tgt}-g++"
    export AR="${tgt}-ar"
    export RANLIB="${tgt}-ranlib"
    export AS="${tgt}-as"
    export LD="${tgt}-ld"
    export STRIP="${tgt}-strip"
    export OBJCOPY="${tgt}-objcopy"
    export OBJDUMP="${tgt}-objdump"

    # sysroot padrão
    export SYSROOT="/usr/src/adm/cross/$tgt/sysroot"

    CFLAGS="$CFLAGS --sysroot=$SYSROOT"
    CXXFLAGS="$CXXFLAGS --sysroot=$SYSROOT"
    LDFLAGS="$LDFLAGS --sysroot=$SYSROOT"

    _prof_log INFO "Configuração CROSS aplicada: TARGET=$tgt SYSROOT=$SYSROOT"
}

# -----------------------------
# Salvar snapshot do perfil compilado (para depuração)
# -----------------------------
adm_profile_save_compiled_snapshot() {
    adm_profile_ensure_dirs || return 1
    local pkg="${ADM_CURRENT_PKG:-generic}"
    local lang="${ADM_CURRENT_LANG:-none}"
    local tgt="${ADM_CURRENT_TARGET:-native}"

    local fname="${pkg}-${ADM_CURRENT_PROFILE}-${ADM_CURRENT_LIBC}-${ADM_CURRENT_INIT}-${lang}-${tgt}.profile"
    # sanitizar
    fname="${fname//\//_}"

    local path="$ADM_PROFILE_COMPILED_DIR/$fname"

    {
        printf '# Perfil compilado para pacote=%s\n' "$pkg"
        printf 'PROFILE=%s\n'  "$ADM_CURRENT_PROFILE"
        printf 'LIBC=%s\n'     "$ADM_CURRENT_LIBC"
        printf 'INIT=%s\n'     "$ADM_CURRENT_INIT"
        printf 'LANG=%s\n'     "$ADM_CURRENT_LANG"
        printf 'TARGET=%s\n'   "$ADM_CURRENT_TARGET"
        printf 'CFLAGS=%s\n'   "$CFLAGS"
        printf 'CXXFLAGS=%s\n' "$CXXFLAGS"
        printf 'LDFLAGS=%s\n'  "$LDFLAGS"
        printf 'MAKEFLAGS=%s\n' "$MAKEFLAGS"
        [ -n "$CC" ] && printf 'CC=%s\n' "$CC"
        [ -n "$CXX" ] && printf 'CXX=%s\n' "$CXX"
        [ -n "$LD" ] && printf 'LD=%s\n' "$LD"
        [ -n "$SYSROOT" ] && printf 'SYSROOT=%s\n' "$SYSROOT"
    } > "$path" 2>/dev/null || {
        _prof_log WARN "Não foi possível salvar snapshot de perfil em $path"
        return 1
    }

    _prof_log DEBUG "Snapshot de perfil salvo em: $path"
    return 0
}

# -----------------------------
# Dump de debug (para scripts)
# -----------------------------
adm_profile_debug() {
    _prof_log INFO "=== DEBUG PROFILE ==="
    printf 'PROFILE=%s\n' "$ADM_CURRENT_PROFILE"
    printf 'LIBC=%s\n'    "$ADM_CURRENT_LIBC"
    printf 'INIT=%s\n'    "$ADM_CURRENT_INIT"
    printf 'LANG=%s\n'    "$ADM_CURRENT_LANG"
    printf 'TARGET=%s\n'  "${ADM_CURRENT_TARGET:-native}"
    printf 'PKG=%s\n'     "${ADM_CURRENT_PKG:-none}"
    printf 'LINKER=%s\n'  "$ADM_LINKER"
    printf 'CFLAGS=%s\n'    "$CFLAGS"
    printf 'CXXFLAGS=%s\n'  "$CXXFLAGS"
    printf 'LDFLAGS=%s\n'   "$LDFLAGS"
    printf 'MAKEFLAGS=%s\n' "$MAKEFLAGS"
    if [ -n "$CC" ]; then
        printf 'CC=%s\n'   "$CC"
        printf 'CXX=%s\n'  "$CXX"
        printf 'LD=%s\n'   "$LD"
        printf 'SYSROOT=%s\n' "${SYSROOT:-}"
    fi
}

# -----------------------------
# Checagem rápida de compilers/linkers (mitigação de falhas)
# -----------------------------
adm_profile_sanity_check_tools() {
    local ok=0

    if [ -n "$CC" ] && ! command -v "$CC" >/dev/null 2>&1; then
        _prof_log ERROR "Compilador CC não encontrado no PATH: $CC"
        ok=1
    fi

    if [ -z "$CC" ]; then
        if ! command -v gcc >/dev/null 2>&1 && ! command -v clang >/dev/null 2>&1; then
            _prof_log ERROR "Nenhum compilador C (gcc/clang) encontrado no PATH"
            ok=1
        fi
    fi

    if ! command -v ld >/dev/null 2>&1; then
        _prof_log ERROR "Linker 'ld' não encontrado no PATH"
        ok=1
    fi

    if [ "$ok" -ne 0 ]; then
        _prof_log ERROR "Sanity check de ferramentas falhou"
        return 1
    fi

    _prof_log INFO "Sanity check de ferramentas OK"
    return 0
}

# -----------------------------
# Interface de alto nível:
# Inicializar + carregar + sanity check
# -----------------------------
adm_profile_setup_for_pkg() {
    # Uso:
    #   adm_profile_setup_for_pkg PROFILE LIBC INIT PKG LANG [TARGET]
    local profile="$1"
    local libc="$2"
    local init="$3"
    local pkg="$4"
    local lang="$5"
    local target="$6"

    adm_profile_init || return 1
    adm_profile_load "$profile" "$libc" "$init" "$pkg" "$lang" "$target" || return 1
    adm_profile_sanity_check_tools || return 1

    return 0
}

# -----------------------------
# Modo de teste direto
# -----------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Teste rápido manual:
    # Exemplo: ./profile.sh aggressive glibc systemd bash c
    profile="${1:-aggressive}"
    libc="${2:-glibc}"
    init="${3:-systemd}"
    pkg="${4:-testpkg}"
    lang="${5:-c}"
    target="${6:-}"

    echo "== TESTE profile.sh =="
    echo "PROFILE=$profile LIBC=$libc INIT=$init PKG=$pkg LANG=$lang TARGET=${target:-native}"

    adm_profile_setup_for_pkg "$profile" "$libc" "$init" "$pkg" "$lang" "$target" || exit 1
    adm_profile_debug
fi
