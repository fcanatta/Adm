#!/usr/bin/env bash
# build_core.sh – Núcleo de build EXTREMO do ADM
#
# Pipeline completo:
#   1) Metafile carregado (MF_*) via adm_meta_load
#   2) source.sh gera sources + build.plan (adm_source_prepare_from_meta)
#   3) build_core:
#        - lê build.plan
#        - configura perfil via profile.sh (compiladores/linkers)
#        - cria chroot seguro
#        - roda configure/build/install dentro do chroot
#        - instala sempre em DESTDIR interno (/dest)
#
# Observações:
#   - Nenhum build roda fora do chroot
#   - Env dentro do chroot é controlado (PATH, CC, CFLAGS, etc.)
#   - Não usa set -e (para não quebrar chamadores), mas trata todos erros.

ADM_ROOT="/usr/src/adm"
ADM_BUILD_ROOT="$ADM_ROOT/build"
ADM_CHROOT_BASE="$ADM_ROOT/chroot"

# Perfil padrão se não vier nada de fora
ADM_BUILD_DEFAULT_PROFILE="${ADM_BUILD_DEFAULT_PROFILE:-normal}"
ADM_BUILD_DEFAULT_LIBC="${ADM_BUILD_DEFAULT_LIBC:-glibc}"
ADM_BUILD_DEFAULT_INIT="${ADM_BUILD_DEFAULT_INIT:-sysv}"

# Pode vir do ambiente ou de scripts superiores
ADM_BUILD_PROFILE="${ADM_BUILD_PROFILE:-$ADM_BUILD_DEFAULT_PROFILE}"
ADM_BUILD_LIBC="${ADM_BUILD_LIBC:-$ADM_BUILD_DEFAULT_LIBC}"
ADM_BUILD_INIT="${ADM_BUILD_INIT:-$ADM_BUILD_DEFAULT_INIT}"

_BUILD_HAVE_UI=0
if declare -F adm_ui_log_info >/dev/null 2>&1; then
    _BUILD_HAVE_UI=1
fi

_build_log() {
    local lvl="$1"; shift || true
    local msg="$*"
    if [ "$_BUILD_HAVE_UI" -eq 1 ]; then
        case "$lvl" in
            INFO)  adm_ui_log_info  "$msg" ;;
            WARN)  adm_ui_log_warn  "$msg" ;;
            ERROR) adm_ui_log_error "$msg" ;;
            DEBUG) adm_ui_log_info  "[DEBUG] $msg" ;;
            *)     adm_ui_log_info  "$msg" ;;
        esac
    else
        printf 'build_core[%s]: %s\n' "$lvl" "$msg" >&2
    fi
}

_build_fail() {
    _build_log ERROR "$*"
    return 1
}

_build_trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# --------------------------------
# Garantir scripts auxiliares
# --------------------------------
_build_ensure_metafile() {
    if declare -F adm_meta_load >/dev/null 2>&1; then
        return 0
    fi
    local f="$ADM_ROOT/scripts/metafile.sh"
    if [ -r "$f" ]; then
        # shellcheck source=/usr/src/adm/scripts/metafile.sh
        . "$f" || _build_fail "Falha ao carregar $f"
        return $?
    fi
    _build_fail "metafile.sh não encontrado em $f"
}

_build_ensure_source() {
    if declare -F adm_source_prepare_from_meta >/dev/null 2>&1; then
        return 0
    fi
    local f="$ADM_ROOT/scripts/source.sh"
    if [ -r "$f" ]; then
        # shellcheck source=/usr/src/adm/scripts/source.sh
        . "$f" || _build_fail "Falha ao carregar $f"
        return $?
    fi
    _build_fail "source.sh não encontrado em $f"
}

_build_ensure_profile() {
    if declare -F adm_profile_setup_for_pkg >/dev/null 2>&1; then
        return 0
    fi
    local f="$ADM_ROOT/scripts/profile.sh"
    if [ -r "$f" ]; then
        # shellcheck source=/usr/src/adm/scripts/profile.sh
        . "$f" || _build_fail "Falha ao carregar $f"
        return $?
    fi
    _build_fail "profile.sh não encontrado em $f"
}

# --------------------------------
# Diretórios específicos do pacote
# --------------------------------
_build_pkg_build_dir() {
    printf '%s/%s-%s\n' "$ADM_BUILD_ROOT" "$MF_NAME" "$MF_VERSION"
}

_build_pkg_dest_dir() {
    local base; base="$(_build_pkg_build_dir)"
    printf '%s/dest\n' "$base"
}

_build_pkg_plan_file() {
    local base; base="$(_build_pkg_build_dir)"
    printf '%s/build.plan\n' "$base"
}

_build_pkg_src_dir() {
    local base; base="$(_build_pkg_build_dir)"
    printf '%s/src\n' "$base"
}

# --------------------------------
# Ler build.plan
# --------------------------------
# Variáveis globais do plano
BUILD_PLAN_SYSTEM=""
BUILD_PLAN_LANG=""
BUILD_PLAN_IS_KERNEL=0
BUILD_PLAN_IS_TOOLCHAIN=0
BUILD_PLAN_IS_LLVM=0
BUILD_PLAN_DOCS=""
BUILD_PLAN_CONFIGURE_CMD=""
BUILD_PLAN_BUILD_CMD=""
BUILD_PLAN_INSTALL_CMD=""
BUILD_PLAN_SRC_DIR=""
BUILD_PLAN_BUILD_DIR=""

_build_reset_plan_vars() {
    BUILD_PLAN_SYSTEM=""
    BUILD_PLAN_LANG=""
    BUILD_PLAN_IS_KERNEL=0
    BUILD_PLAN_IS_TOOLCHAIN=0
    BUILD_PLAN_IS_LLVM=0
    BUILD_PLAN_DOCS=""
    BUILD_PLAN_CONFIGURE_CMD=""
    BUILD_PLAN_BUILD_CMD=""
    BUILD_PLAN_INSTALL_CMD=""
    BUILD_PLAN_SRC_DIR=""
    BUILD_PLAN_BUILD_DIR=""
}

_build_read_plan() {
    local plan="$(_build_pkg_plan_file)"

    _build_reset_plan_vars

    if [ ! -f "$plan" ]; then
        _build_fail "build.plan não encontrado: $plan (rode adm_source_prepare_from_meta antes)"
        return 1
    fi

    if [ ! -r "$plan" ]; then
        _build_fail "build.plan não legível: $plan"
        return 1
    fi

    local line lineno=0 key val
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        line="$(_build_trim "$line")"

        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue

        case "$line" in
            *=*) ;;
            *)
                _build_fail "Linha inválida no build.plan ($plan:$lineno): '$line'"
                return 1
                ;;
        esac

        key="${line%%=*}"
        val="${line#*=}"
        key="$(_build_trim "$key")"
        val="$(_build_trim "$val")"

        case "$key" in
            BUILD_SYSTEM)   BUILD_PLAN_SYSTEM="$val" ;;
            PRIMARY_LANG)   BUILD_PLAN_LANG="$val" ;;
            IS_KERNEL)      BUILD_PLAN_IS_KERNEL="$val" ;;
            IS_TOOLCHAIN)   BUILD_PLAN_IS_TOOLCHAIN="$val" ;;
            IS_LLVM)        BUILD_PLAN_IS_LLVM="$val" ;;
            DOCS)           BUILD_PLAN_DOCS="$val" ;;
            CONFIGURE_CMD)  BUILD_PLAN_CONFIGURE_CMD="$val" ;;
            BUILD_CMD)      BUILD_PLAN_BUILD_CMD="$val" ;;
            INSTALL_CMD)    BUILD_PLAN_INSTALL_CMD="$val" ;;
            SRC_DIR)        BUILD_PLAN_SRC_DIR="$val" ;;
            BUILD_DIR)      BUILD_PLAN_BUILD_DIR="$val" ;;
            *)
                _build_log WARN "Chave desconhecida em build.plan ($key) ignorada"
                ;;
        esac
    done < "$plan"

    [ -z "$BUILD_PLAN_SYSTEM" ] && BUILD_PLAN_SYSTEM="manual"
    [ -z "$BUILD_PLAN_LANG" ]   && BUILD_PLAN_LANG="unknown"

    _build_log INFO "Plano carregado: system=$BUILD_PLAN_SYSTEM lang=$BUILD_PLAN_LANG kernel=$BUILD_PLAN_IS_KERNEL toolchain=$BUILD_PLAN_IS_TOOLCHAIN"

    return 0
}

# --------------------------------
# Chroot seguro
# --------------------------------
_build_realpath() {
    if command -v realpath >/dev/null 2>&1; then
        realpath -m "$1"
    elif command -v readlink >/dev/null 2>&1; then
        readlink -f "$1" 2>/dev/null || printf '%s\n' "$1"
    else
        printf '%s\n' "$1"
    fi
}

_build_chroot_root() {
    printf '%s/%s-%s\n' "$ADM_CHROOT_BASE" "$MF_NAME" "$MF_VERSION"
}

_build_ensure_under_root() {
    local p="$(_build_realpath "$1")"
    local root="$(_build_realpath "$ADM_ROOT")"

    if [ -z "$p" ] || [ -z "$root" ]; then
        _build_fail "Não foi possível resolver caminhos para segurança de chroot"
        return 1
    fi

    case "$p" in
        "$root" | "$root"/*)
            return 0
            ;;
        *)
            _build_fail "Caminho '$p' não está sob '$root' – operação negada"
            return 1
            ;;
    esac
}

_build_chroot_init_dirs() {
    local croot="$(_build_chroot_root)"

    _build_ensure_under_root "$croot" || return 1

    if ! mkdir -p "$croot" 2>/dev/null; then
        _build_fail "Não foi possível criar root do chroot: $croot"
        return 1
    fi

    # Diretórios básicos
    for d in dev proc sys run tmp build dest usr bin lib lib64 etc var; do
        mkdir -p "$croot/$d" 2>/dev/null || {
            _build_fail "Falha ao criar diretório dentro do chroot: $croot/$d"
            return 1
        }
    done

    return 0
}

_build_mount_bind() {
    local src="$1" dst="$2"
    _build_ensure_under_root "$dst" || return 1

    if ! mountpoint -q "$dst" 2>/dev/null; then
        if ! mount --bind "$src" "$dst" 2>/dev/null; then
            _build_fail "Falha ao montar bind $src -> $dst"
            return 1
        fi
    fi
    return 0
}

_build_mount_fs() {
    local fstype="$1"
    local dst="$2"
    _build_ensure_under_root "$dst" || return 1

    if ! mountpoint -q "$dst" 2>/dev/null; then
        if ! mount -t "$fstype" "$fstype" "$dst" 2>/dev/null; then
            _build_fail "Falha ao montar $fstype em $dst"
            return 1
        fi
    fi
    return 0
}

_build_umount_safe() {
    local dst="$1"
    if mountpoint -q "$dst" 2>/dev/null; then
        umount "$dst" 2>/dev/null || _build_log WARN "Falha ao desmontar $dst (pode estar ocupado)"
    fi
}
# --------------------------------
# Preparar chroot de build
# --------------------------------
_build_setup_chroot() {
    local croot="$(_build_chroot_root)"
    local bdir="$(_build_pkg_build_dir)"
    local sdir="$(_build_pkg_src_dir)"
    local destdir="$(_build_pkg_dest_dir)"

    adm_source_init_dirs 2>/dev/null || true  # caso ainda não exista build dirs
    if ! mkdir -p "$bdir" "$sdir" "$destdir" 2>/dev/null; then
        _build_fail "Não foi possível garantir diretórios de build para chroot"
        return 1
    fi

    _build_chroot_init_dirs || return 1

    # Montagens dentro do chroot
    # /build -> build do pacote (onde ficam src e obj)
    if ! mkdir -p "$croot/build" 2>/dev/null; then
        _build_fail "Não foi possível criar /build no chroot"
        return 1
    fi
    _build_mount_bind "$bdir" "$croot/build" || return 1

    # /dest -> DESTDIR do pacote
    if ! mkdir -p "$croot/dest" 2>/dev/null; then
        _build_fail "Não foi possível criar /dest no chroot"
        return 1
    fi
    _build_mount_bind "$destdir" "$croot/dest" || return 1

    # /usr/src/adm -> somente leitura pode ser interessante, mas aqui montamos bind normal
    mkdir -p "$croot/usr/src" 2>/dev/null || true
    mkdir -p "$croot/usr/src/adm" 2>/dev/null || true
    _build_mount_bind "$ADM_ROOT" "$croot/usr/src/adm" || return 1

    # /dev /proc /sys /run – básicos
    _build_mount_fs devtmpfs "$croot/dev"  || return 1 || true
    _build_mount_fs proc     "$croot/proc" || return 1 || true
    _build_mount_fs sysfs    "$croot/sys"  || return 1 || true
    _build_mount_fs tmpfs    "$croot/run"  || return 1 || true

    _build_log INFO "Chroot preparado em: $croot"
    return 0
}

_build_teardown_chroot() {
    local croot="$(_build_chroot_root)"

    _build_umount_safe "$croot/run"
    _build_umount_safe "$croot/sys"
    _build_umount_safe "$croot/proc"
    _build_umount_safe "$croot/dev"
    _build_umount_safe "$croot/usr/src/adm"
    _build_umount_safe "$croot/dest"
    _build_umount_safe "$croot/build"

    # Não remove o croot para facilitar debug; outro script pode limpar depois
    _build_log INFO "Chroot desmontado: $croot"
}

# --------------------------------
# Execução dentro do chroot
# --------------------------------
_build_env_for_chroot() {
    # Cria um env bem controlado:
    #  - PATH, HOME, TERM, MAKEFLAGS, CC/CXX/CFLAGS/etc. herdados do shell atual
    #  - remove envs perigosos: LD_PRELOAD, LD_LIBRARY_PATH, etc.
    env -i \
        PATH="${PATH:-/usr/bin:/bin}" \
        HOME="/root" \
        TERM="${TERM:-xterm}" \
        USER="root" \
        LANG="${LANG:-C}" \
        LC_ALL="${LC_ALL:-C}" \
        MAKEFLAGS="${MAKEFLAGS:-}" \
        CC="${CC:-}" \
        CXX="${CXX:-}" \
        AR="${AR:-}" \
        RANLIB="${RANLIB:-}" \
        AS="${AS:-}" \
        LD="${LD:-}" \
        STRIP="${STRIP:-}" \
        OBJCOPY="${OBJCOPY:-}" \
        OBJDUMP="${OBJDUMP:-}" \
        CFLAGS="${CFLAGS:-}" \
        CXXFLAGS="${CXXFLAGS:-}" \
        LDFLAGS="${LDFLAGS:-}" \
        PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}" \
        PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR:-}" \
        DESTDIR="/dest" \
        SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}" \
        ADM_BUILD_PROFILE="$ADM_BUILD_PROFILE" \
        ADM_BUILD_LIBC="$ADM_BUILD_LIBC" \
        ADM_BUILD_INIT="$ADM_BUILD_INIT"
}

_build_in_chroot() {
    # Uso:
    #   _build_in_chroot "descrição" "comando..."
    local desc="$1"; shift || true
    local cmd="$*"
    local croot="$(_build_chroot_root)"
    local srcdir="$BUILD_PLAN_SRC_DIR"

    [ -z "$srcdir" ] && srcdir="$(_build_pkg_src_dir)"

    if [ ! -d "$croot" ]; then
        _build_fail "_build_in_chroot: chroot não inicializado: $croot"
        return 1
    fi
    if [ ! -d "$srcdir" ]; then
        _build_fail "_build_in_chroot: SRC_DIR não existe: $srcdir"
        return 1
    fi

    # Comando final: cd para srcdir e roda comando
    local inner_cmd="cd /build/src && $cmd"
    # Se BUILD_PLAN_SRC_DIR aponta para outra coisa dentro de /build, ajustamos
    if [ "$srcdir" != "$(_build_pkg_src_dir)" ]; then
        # Tenta manter path relativo em /build
        inner_cmd="cd \"${srcdir#$(_build_pkg_build_dir)/}\" && $cmd"
        # se não estiver sob /build, fallback pra src padrão
        case "$srcdir" in
            "$(_build_pkg_build_dir)"* ) ;;
            *)
                inner_cmd="cd /build/src && $cmd"
                ;;
        esac
    fi

    if [ "$_BUILD_HAVE_UI" -eq 1 ]; then
        adm_ui_log_info "▶ [chroot] $desc: $cmd"
    else
        _build_log INFO "▶ [chroot] $desc: $cmd"
    fi

    _build_env_for_chroot \
    chroot "$croot" /usr/bin/env bash -lc "$inner_cmd"
}

_build_run_phase() {
    # Uso:
    #   _build_run_phase "nome_fase" "comando..."
    local phase="$1"; shift || true
    local cmd="$*"

    if [ -z "$cmd" ]; then
        _build_log DEBUG "Fase '$phase' não possui comando (pulado)"
        return 0
    fi

    if [ "$_BUILD_HAVE_UI" -eq 1 ]; then
        adm_ui_with_spinner "[$MF_NAME] $phase" _build_in_chroot "$phase" "$cmd"
        return $?
    else
        _build_in_chroot "$phase" "$cmd"
        return $?
    fi
}

# --------------------------------
# Integração com profile.sh (perfis / toolchains)
# --------------------------------
_build_setup_profile_for_plan() {
    _build_ensure_profile || return 1

    local lang="$BUILD_PLAN_LANG"
    local pkg="$MF_NAME"
    local target="${ADM_CURRENT_TARGET:-}"  # se existir

    # Perfil global vem de ADM_BUILD_PROFILE/ADM_BUILD_LIBC/ADM_BUILD_INIT
    # Usa interface de alto nível:
    #   adm_profile_setup_for_pkg PROFILE LIBC INIT PKG LANG [TARGET]
    adm_profile_setup_for_pkg "$ADM_BUILD_PROFILE" "$ADM_BUILD_LIBC" "$ADM_BUILD_INIT" "$pkg" "$lang" "$target" || {
        _build_fail "Falha ao configurar perfil para pacote '$pkg'"
        return 1
    }

    _build_log INFO "Perfil aplicado para '$pkg' (profile=$ADM_BUILD_PROFILE libc=$ADM_BUILD_LIBC init=$ADM_BUILD_INIT lang=$lang target=${target:-native})"
    return 0
}

# --------------------------------
# Ajustes por tipo especial (kernel/toolchain/llvm)
# --------------------------------
_build_adjust_commands_for_special() {
    # Permite sobrescrever comandos se o plano for kernel/toolchain/llvm muito específicos
    # Por enquanto, deixamos genérico e deixamos script de toolchain lidar com passes.
    # Aqui apenas fazemos ajustes leves.
    if [ "$BUILD_PLAN_IS_KERNEL" = "1" ]; then
        # Kernel costuma querer O=builddir, ARCH e CROSS_COMPILE; profile já cuida de target.
        BUILD_PLAN_CONFIGURE_CMD="${BUILD_PLAN_CONFIGURE_CMD:-""}"
        BUILD_PLAN_BUILD_CMD="${BUILD_PLAN_BUILD_CMD:-make}"
        BUILD_PLAN_INSTALL_CMD="${BUILD_PLAN_INSTALL_CMD:-"make modules_install INSTALL_MOD_PATH=\"\${DESTDIR}\""}"
        _build_log INFO "Comandos ajustados para kernel"
    fi

    if [ "$BUILD_PLAN_IS_TOOLCHAIN" = "1" ]; then
        # Toolchain será tratada externamente em passes; aqui só garantimos comandos básicos.
        BUILD_PLAN_CONFIGURE_CMD="${BUILD_PLAN_CONFIGURE_CMD:-"./configure"}"
        BUILD_PLAN_BUILD_CMD="${BUILD_PLAN_BUILD_CMD:-"make"}"
        BUILD_PLAN_INSTALL_CMD="${BUILD_PLAN_INSTALL_CMD:-"make install"}"
        _build_log INFO "Comandos ajustados para toolchain"
    fi

    if [ "$BUILD_PLAN_IS_LLVM" = "1" ]; then
        # LLVM gosta de cmake + ninja; se plano não configurar, ajustamos
        if [ "$BUILD_PLAN_SYSTEM" = "cmake" ] && [ -z "$BUILD_PLAN_BUILD_CMD" ]; then
            BUILD_PLAN_BUILD_CMD="cmake --build build"
            BUILD_PLAN_INSTALL_CMD="cmake --install build --prefix \"\${DESTDIR}/usr\""
        fi
        _build_log INFO "Comandos ajustados para LLVM"
    fi

    return 0
}
# --------------------------------
# Pipeline de build interno
# --------------------------------
_build_pipeline() {
    # 1) configurar perfil (compiladores, linkers, flags)
    _build_setup_profile_for_plan || return 1

    # 2) preparar chroot
    _build_setup_chroot || return 1

    local rc=0

    # 3) ajustar comandos para casos especiais
    _build_adjust_commands_for_special || rc=1

    # 4) Fases de build
    _build_run_phase "configure" "$BUILD_PLAN_CONFIGURE_CMD" || rc=1
    if [ "$rc" -eq 0 ]; then
        _build_run_phase "build" "$BUILD_PLAN_BUILD_CMD" || rc=1
    fi
    if [ "$rc" -eq 0 ]; then
        _build_run_phase "install (DESTDIR=/dest)" "$BUILD_PLAN_INSTALL_CMD" || rc=1
    fi

    # 5) desmontar chroot
    _build_teardown_chroot

    if [ "$rc" -ne 0 ]; then
        _build_fail "Uma ou mais fases de build falharam para $MF_NAME-$MF_VERSION"
        return 1
    fi

    _build_log INFO "Build concluído em DESTDIR: $(_build_pkg_dest_dir)"
    return 0
}

# --------------------------------
# Função pública principal
# --------------------------------
adm_build_core_from_meta() {
    # Supõe que MF_* já está carregado via adm_meta_load
    _build_ensure_metafile || return 1
    _build_ensure_source || return 1

    if [ -z "${MF_NAME:-}" ] || [ -z "${MF_VERSION:-}" ]; then
        _build_fail "Metafile não carregado (MF_NAME/MF_VERSION vazios); use adm_meta_load antes"
        return 1
    fi

    if [ "$_BUILD_HAVE_UI" -eq 1 ]; then
        adm_ui_set_context "build" "$MF_NAME"
        adm_ui_set_log_file "build" "$MF_NAME" || return 1

        adm_ui_with_spinner "Preparando fontes de $MF_NAME" adm_source_prepare_from_meta || return 1
        adm_ui_with_spinner "Carregando plano de build de $MF_NAME" _build_read_plan || return 1
        adm_ui_with_spinner "Executando build de $MF_NAME" _build_pipeline || return 1
    else
        adm_source_prepare_from_meta || return 1
        _build_read_plan || return 1
        _build_pipeline || return 1
    fi

    return 0
}

# Versão que recebe caminho de metafile
adm_build_core_from_file() {
    local metafile="$1"
    if [ -z "$metafile" ]; then
        _build_fail "adm_build_core_from_file: precisa do caminho do metafile"
        return 1
    fi

    _build_ensure_metafile || return 1
    if ! adm_meta_load "$metafile"; then
        _build_fail "Falha ao carregar metafile: $metafile"
        return 1
    fi

    adm_build_core_from_meta
}

# --------------------------------
# Modo CLI (teste direto)
# --------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Exemplo:
    #   ./build_core.sh /usr/src/adm/repo/apps/bash/metafile
    if [ "$#" -ne 1 ]; then
        echo "Uso: $0 /caminho/para/metafile" >&2
        exit 1
    fi

    metafile="$1"
    if ! adm_build_core_from_file "$metafile"; then
        echo "Build falhou para metafile: $metafile" >&2
        exit 1
    fi

    echo "Build concluído. DESTDIR: $(_build_pkg_dest_dir)"
fi
