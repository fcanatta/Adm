#!/usr/bin/env bash
# lib/adm/stages.sh
#
# Subsistema de ESTÁGIOS do ADM
#
# Responsabilidades:
#   - Orquestrar os estágios de construção:
#       * cross      → toolchain cross + ferramentas temporárias
#       * temp       → (opcional) ferramentas temporárias adicionais
#       * stage2     → chroot inicial / rootfs base
#       * base       → sistema base dentro do chroot/rootfs
#   - Configurar automaticamente:
#       * PROFILE (aggressive/normal/minimum)
#       * uso de chroot (ADM_BUILD_USE_CHROOT / ADM_CHROOT_ROOT)
#       * raiz de instalação (ADM_INSTALL_ROOT)
#   - Ler listas de pacotes de arquivos externos (stages.d/*.list) OU usar
#     defaults embutidos.
#   - Registrar progresso por estágio (status OK/FAIL por pacote).
#   - Permitir retomar um estágio: pacotes já OK são pulados.
#
# Nenhum erro silencioso: tudo é logado claramente.
#
# ARQUITETURA:
#
#   Variáveis principais:
#     ADM_ROOT                – raiz do programa (ex: /usr/src/adm)
#     ADM_STATE_DIR           – estado, dbs, stages
#     ADM_DESTDIR_DIR         – destdirs dos builds
#     ADM_CROSS_TOOLS_DIR     – raiz para cross-toolchain
#     ADM_ROOTFS_STAGE2_DIR   – rootfs para stage2/base (chroot)
#
#   Estágios BUILT-IN:
#     cross:
#       PROFILE      = minimum
#       USE_CHROOT   = 0
#       INSTALL_ROOT = ADM_CROSS_TOOLS_DIR
#
#     temp:
#       PROFILE      = minimum
#       USE_CHROOT   = 0
#       INSTALL_ROOT = ADM_CROSS_TOOLS_DIR
#
#     stage2:
#       PROFILE      = minimum
#       USE_CHROOT   = 1
#       INSTALL_ROOT = ADM_ROOTFS_STAGE2_DIR
#
#     base:
#       PROFILE      = normal
#       USE_CHROOT   = 1
#       INSTALL_ROOT = ADM_ROOTFS_STAGE2_DIR
#
#   Ordem natural: cross → temp → stage2 → base
#
#   Arquivos de lista de pacotes (opcionais, override dos defaults):
#     $ADM_ROOT/stages.d/cross.list
#     $ADM_ROOT/stages.d/temp.list
#     $ADM_ROOT/stages.d/stage2.list
#     $ADM_ROOT/stages.d/base.list
#
#   Formato: uma entrada por linha "categoria/pacote", comentários com '#'.
###############################################################################
# Proteção contra múltiplos loads
###############################################################################
if [ -n "${ADM_STAGES_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
ADM_STAGES_LOADED=1
###############################################################################
# Dependências: log + core + build + pkg + chroot
###############################################################################
# -------- LOG ---------------------------------------------------------
if ! command -v adm_log_stage >/dev/null 2>&1; then
    # Fallback mínimo se log.sh ainda não foi carregado
    adm_log()        { printf '%s\n' "$*" >&2; }
    adm_log_info()   { adm_log "[INFO]   $*"; }
    adm_log_warn()   { adm_log "[WARN]   $*"; }
    adm_log_error()  { adm_log "[ERROR]  $*"; }
    adm_log_debug()  { :; }
    adm_log_stage()  { adm_log "[STAGE]  $*"; }
    adm_log_pkg()    { adm_log "[PKG]    $*"; }
fi

# -------- CORE (paths, helpers) --------------------------------------
if command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_core_init_paths
fi

if ! command -v adm_require_root >/dev/null 2>&1; then
    adm_require_root() {
        if [ "$(id -u 2>/dev/null)" != "0" ]; then
            adm_log_error "Este comando requer privilégios de root."
            return 1
        fi
        return 0
    }
fi

if ! command -v adm_mkdir_p >/dev/null 2>&1; then
    adm_mkdir_p() {
        if [ $# -ne 1 ]; then
            adm_log_error "adm_mkdir_p requer 1 argumento: DIR"
            return 1
        fi
        mkdir -p -- "$1" 2>/dev/null || {
            adm_log_error "Falha ao criar diretório: %s" "$1"
            return 1
        }
    }
fi

# -------- BUILD / PKG--------------------------------------------------
if ! command -v adm_pkg_install_single >/dev/null 2>&1; then
    adm_log_error "pkg.sh não carregado; adm_pkg_install_single ausente. stages.sh não poderá instalar pacotes."
fi

if ! command -v adm_build_package >/dev/null 2>&1; then
    adm_log_error "build.sh não carregado; adm_build_package ausente. stages.sh ficará limitado."
fi

# -------- ENV / PROFILES (opcional) ----------------------------------
if ! command -v adm_env_apply_profile >/dev/null 2>&1; then
    adm_env_apply_profile() { :; }
fi

# -------- PATHS GLOBAIS ----------------------------------------------
: "${ADM_ROOT:=${ADM_ROOT:-/usr/src/adm}}"
: "${ADM_STATE_DIR:=${ADM_STATE_DIR:-$ADM_ROOT/state}}"
: "${ADM_DESTDIR_DIR:=${ADM_DESTDIR_DIR:-$ADM_ROOT/destdir}}"
: "${ADM_LOG_DIR:=${ADM_LOG_DIR:-$ADM_ROOT/logs}}"

: "${ADM_CROSS_TOOLS_DIR:=${ADM_CROSS_TOOLS_DIR:-$ADM_ROOT/cross-tools}}"
: "${ADM_ROOTFS_STAGE2_DIR:=${ADM_ROOTFS_STAGE2_DIR:-$ADM_ROOT/rootfs/stage2}}"

: "${ADM_STAGES_DIR:=${ADM_STAGES_DIR:-$ADM_STATE_DIR/stages}}"
: "${ADM_STAGES_LIST_DIR:=${ADM_STAGES_LIST_DIR:-$ADM_ROOT/stages.d}}"

adm_mkdir_p "$ADM_STATE_DIR"      || adm_log_error "Falha ao criar ADM_STATE_DIR: %s" "$ADM_STATE_DIR"
adm_mkdir_p "$ADM_STAGES_DIR"     || adm_log_error "Falha ao criar ADM_STAGES_DIR: %s" "$ADM_STAGES_DIR"
adm_mkdir_p "$ADM_STAGES_LIST_DIR"|| adm_log_debug "Falha ao criar ADM_STAGES_LIST_DIR: %s (pode ser criado depois)" "$ADM_STAGES_LIST_DIR" || true

###############################################################################
# Helpers internos
###############################################################################

adm_stages__trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

adm_stages__status_file() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_stages__status_file requer 1 argumento: STAGE"
        return 1
    fi
    local s="$1"
    printf '%s/%s.status\n' "$ADM_STAGES_DIR" "$s"
}

adm_stages__validate_stage_name() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_stages__validate_stage_name requer 1 argumento."
        return 1
    fi
    local s="$1"
    case "$s" in
        ''|*[!a-zA-Z0-9_-]*)
            adm_log_error "Nome de estágio inválido: '%s'" "$s"
            return 1
            ;;
    esac
    return 0
}

adm_stages__pkg_spec_validate() {
    # formato categoria/pacote
    if [ $# -ne 1 ]; then
        adm_log_error "adm_stages__pkg_spec_validate requer 1 argumento: CATEGORIA/PACOTE"
        return 1
    fi
    local spec="$1"

    case "$spec" in
        */*)
            : ;;
        *)
            adm_log_error "Especificação de pacote inválida (esperado categoria/pacote): %s" "$spec"
            return 1
            ;;
    esac
    return 0
}

###############################################################################
# Definições de estágios (atributos)
###############################################################################

# Atributos:
#   ADM_STAGE_<name>_DESC
#   ADM_STAGE_<name>_PROFILE       (minimum|normal|aggressive)
#   ADM_STAGE_<name>_USE_CHROOT    (0|1)
#   ADM_STAGE_<name>_INSTALL_ROOT  (path)

# Lista de estágios conhecidos (ordem natural)
ADM_STAGES_ORDER=("cross" "temp" "stage2" "base")

adm_stages__define_defaults() {
    # cross
    ADM_STAGE_cross_DESC="Cross toolchain e ferramentas temporárias em cross-tools"
    ADM_STAGE_cross_PROFILE="minimum"
    ADM_STAGE_cross_USE_CHROOT=0
    ADM_STAGE_cross_INSTALL_ROOT="$ADM_CROSS_TOOLS_DIR"

    # temp
    ADM_STAGE_temp_DESC="Ferramentas temporárias adicionais no cross-tools"
    ADM_STAGE_temp_PROFILE="minimum"
    ADM_STAGE_temp_USE_CHROOT=0
    ADM_STAGE_temp_INSTALL_ROOT="$ADM_CROSS_TOOLS_DIR"

    # stage2
    ADM_STAGE_stage2_DESC="Stage2 inicial dentro do rootfs (chroot) – toolchain final"
    ADM_STAGE_stage2_PROFILE="minimum"
    ADM_STAGE_stage2_USE_CHROOT=1
    ADM_STAGE_stage2_INSTALL_ROOT="$ADM_ROOTFS_STAGE2_DIR"

    # base
    ADM_STAGE_base_DESC="Sistema base completo dentro do rootfs (chroot)"
    ADM_STAGE_base_PROFILE="normal"
    ADM_STAGE_base_USE_CHROOT=1
    ADM_STAGE_base_INSTALL_ROOT="$ADM_ROOTFS_STAGE2_DIR"
}

adm_stages__define_defaults

adm_stage_attr_get() {
    # args: STAGE ATTR
    if [ $# -ne 2 ]; then
        adm_log_error "adm_stage_attr_get requer 2 argumentos: STAGE ATTR"
        return 1
    fi
    local stage="$1" attr="$2"
    adm_stages__validate_stage_name "$stage" || return 1

    local var="ADM_STAGE_${stage}_${attr}"
    if eval '[ -z "${'"$var"'+x}" ]'; then
        adm_log_warn "Atributo '%s' não definido para stage '%s'." "$attr" "$stage"
        return 1
    fi
    eval "printf '%s\n' \"\${$var}\""
    return 0
}

###############################################################################
# Listas de pacotes por estágio
###############################################################################

# Defaults embutidos – usados se NÃO existir um arquivo em stages.d/<stage>.list
adm_stages__builtin_list() {
    # args: STAGE
    if [ $# -ne 1 ]; then
        adm_log_error "adm_stages__builtin_list requer 1 argumento: STAGE"
        return 1
    fi
    local stage="$1"

    case "$stage" in
        cross)
            # Exemplo default; podem ser sobrescritos por stages.d/cross.list
            cat <<'EOF'
cross/binutils-pass1
cross/gcc-pass1
cross/linux-headers
cross/glibc
cross/binutils-pass2
cross/gcc-pass2
EOF
            ;;
        temp)
            cat <<'EOF'
temp/m4
temp/ncurses
temp/bash
temp/coreutils
temp/file
temp/findutils
temp/gawk
temp/grep
temp/gzip
temp/make
temp/patch
temp/sed
temp/tar
temp/xz
EOF
            ;;
        stage2)
            # seguindo pedido original: Gettext, Bison, Perl, Python, Texinfo, Util-linux
            cat <<'EOF'
base/gettext
base/bison
base/perl
base/python
base/texinfo
base/util-linux
EOF
            ;;
        base)
            # apenas exemplo de base; na prática, usuário deve customizar via stages.d/base.list
            cat <<'EOF'
base/linux-headers
base/glibc
base/zlib
base/file
base/binutils
base/gcc
base/coreutils
base/grep
base/sed
base/gawk
base/gzip
base/bzip2
base/xz
base/findutils
base/diffutils
base/patch
base/tar
base/make
base/bash
base/shadow
base/psmisc
base/procps-ng
base/util-linux
base/e2fsprogs
base/kbd
base/sysvinit
EOF
            ;;
        *)
            adm_log_error "Não há lista built-in para stage '%s'." "$stage"
            return 1
            ;;
    esac
    return 0
}

# Carrega lista de pacotes para um estágio em um array global: ADM_STAGE_PKGS[@]
adm_stage_load_packages() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_stage_load_packages requer 1 argumento: STAGE"
        return 1
    fi
    local stage="$1"
    adm_stages__validate_stage_name "$stage" || return 1

    local list_file="$ADM_STAGES_LIST_DIR/$stage.list"
    local line spec
    ADM_STAGE_PKGS=()

    if [ -f "$list_file" ]; then
        adm_log_stage "Usando lista de pacotes externa para stage '%s': %s" "$stage" "$list_file"
        while IFS= read -r line || [ -n "$line" ]; do
            line="$(adm_stages__trim "$line")"
            [ -z "$line" ] && continue
            case "$line" in
                \#*) continue ;;
            esac
            spec="$line"
            adm_stages__pkg_spec_validate "$spec" || return 1
            ADM_STAGE_PKGS+=("$spec")
        done <"$list_file"
    else
        adm_log_stage "Usando lista built-in de pacotes para stage '%s' (stages.d/%s.list não encontrado)." "$stage" "$stage"
        while IFS= read -r line || [ -n "$line" ]; do
            line="$(adm_stages__trim "$line")"
            [ -z "$line" ] && continue
            case "$line" in
                \#*) continue ;;
            esac
            spec="$line"
            adm_stages__pkg_spec_validate "$spec" || return 1
            ADM_STAGE_PKGS+=("$spec")
        done <<EOF
$(adm_stages__builtin_list "$stage")
EOF
    fi

    if [ "${#ADM_STAGE_PKGS[@]}" -eq 0 ]; then
        adm_log_warn "Stage '%s' não possui pacotes na lista (talvez vazio de propósito?)." "$stage"
    fi

    return 0
}

###############################################################################
# Status de estágios
###############################################################################

# Formato do status-file:
#   OK   categoria/pacote
#   FAIL categoria/pacote
#
# Sempre que um pacote é reprocessado, uma nova linha é adicionada.
# O estado efetivo é a ÚLTIMA linha para aquele pacote.

adm_stage_pkg_status_get() {
    # args: STAGE PKG_SPEC
    if [ $# -ne 2 ]; then
        adm_log_error "adm_stage_pkg_status_get requer 2 argumentos: STAGE PKG_SPEC"
        return 1
    fi
    local stage="$1" spec="$2"
    local sf
    sf="$(adm_stages__status_file "$stage")" || return 1

    [ -f "$sf" ] || { printf 'none\n'; return 0; }

    # Pega a última ocorrência
    local line status="none"
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
        esac
        # formato: STATUS SPEC
        local st pkg
        st="${line%% *}"
        pkg="${line#* }"
        if [ "$pkg" = "$spec" ]; then
            status="$st"
        fi
    done <"$sf"

    printf '%s\n' "$status"
    return 0
}

adm_stage_pkg_status_set() {
    # args: STAGE PKG_SPEC STATUS
    if [ $# -ne 3 ]; then
        adm_log_error "adm_stage_pkg_status_set requer 3 argumentos: STAGE PKG_SPEC STATUS"
        return 1
    fi
    local stage="$1" spec="$2" status="$3"
    local sf
    sf="$(adm_stages__status_file "$stage")" || return 1

    case "$status" in
        OK|FAIL) : ;;
        *)
            adm_log_error "STATUS inválido em adm_stage_pkg_status_set: %s (use OK|FAIL)" "$status"
            return 1
            ;;
    esac

    adm_mkdir_p "$(dirname "$sf")" || return 1

    # Apenas append; leitura pega a última
    printf '%s %s\n' "$status" "$spec" >>"$sf" 2>/dev/null || {
        adm_log_error "Não foi possível atualizar status de stage '%s' em %s." "$stage" "$sf"
        return 1
    }

    return 0
}

adm_stage_show_status() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_stage_show_status requer 1 argumento: STAGE"
        return 1
    fi
    local stage="$1"
    local sf
    sf="$(adm_stages__status_file "$stage")" || return 1

    if [ ! -f "$sf" ]; then
        adm_log_stage "Stage '%s' ainda não possui status registrado." "$stage"
        return 0
    fi

    adm_log_stage "Status atual de stage '%s' (arquivo: %s):" "$stage" "$sf"
    cat "$sf"
    return 0
}

adm_stage_reset_status() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_stage_reset_status requer 1 argumento: STAGE"
        return 1
    fi
    local stage="$1"
    local sf
    sf="$(adm_stages__status_file "$stage")" || return 1

    if [ -f "$sf" ]; then
        rm -f -- "$sf" 2>/dev/null || {
            adm_log_error "Não foi possível apagar status de stage '%s' (%s)." "$stage" "$sf"
            return 1
        }
    fi
    adm_log_stage "Status do stage '%s' resetado (builds serão reprocessados)." "$stage"
    return 0
}

###############################################################################
# Configuração de ambiente por estágio
###############################################################################

# ADM_STAGE_RESUME=1 → manter status (default, resume automático)
# ADM_STAGE_FORCE=1  → ignora status, força re-build de todos os pacotes

adm_stage_apply_env() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_stage_apply_env requer 1 argumento: STAGE"
        return 1
    fi
    local stage="$1"

    local profile use_chroot install_root
    profile="$(adm_stage_attr_get "$stage" "PROFILE" 2>/dev/null || echo "normal")"
    use_chroot="$(adm_stage_attr_get "$stage" "USE_CHROOT" 2>/dev/null || echo "0")"
    install_root="$(adm_stage_attr_get "$stage" "INSTALL_ROOT" 2>/dev/null || echo "/")"

    # Perfil
    ADM_PROFILE_NAME="$profile"
    export ADM_PROFILE_NAME

    # Chroot
    ADM_BUILD_USE_CHROOT="$use_chroot"
    export ADM_BUILD_USE_CHROOT

    if [ "$use_chroot" -eq 1 ]; then
        ADM_CHROOT_ROOT="$install_root"
        export ADM_CHROOT_ROOT
    fi

    # Raiz de instalação para pkg.sh
    ADM_INSTALL_ROOT="$install_root"
    export ADM_INSTALL_ROOT

    adm_log_stage "Ambiente de stage '%s': profile=%s, use_chroot=%s, install_root=%s" \
        "$stage" "$profile" "$use_chroot" "$install_root"

    # Aplica profile (CFLAGS/CXXFLAGS/etc)
    adm_env_apply_profile || adm_log_warn "Falha ao aplicar profile '%s' para stage '%s' (prosseguindo)." "$profile" "$stage"

    # Garante diretórios básicos
    adm_mkdir_p "$ADM_INSTALL_ROOT" || adm_log_error "Falha ao criar raiz de instalação: %s" "$ADM_INSTALL_ROOT"

    if [ "$use_chroot" -eq 1 ]; then
        adm_mkdir_p "$ADM_CHROOT_ROOT" || adm_log_error "Falha ao criar rootfs do chroot: %s" "$ADM_CHROOT_ROOT"
    fi

    return 0
}

###############################################################################
# Execução de um pacote em um stage
###############################################################################

adm_stage_run_pkg() {
    # args: STAGE PKG_SPEC
    if [ $# -ne 2 ]; then
        adm_log_error "adm_stage_run_pkg requer 2 argumentos: STAGE CATEGORIA/PACOTE"
        return 1
    fi
    local stage="$1" spec="$2"
    adm_stages__pkg_spec_validate "$spec" || return 1

    local category="${spec%%/*}"
    local pkg="${spec##*/}"

    # Decide se pula pacote já OK
    local status
    if [ "${ADM_STAGE_FORCE:-0}" -ne 1 ]; then
        status="$(adm_stage_pkg_status_get "$stage" "$spec")" || status="none"
        case "$status" in
            OK)
                adm_log_stage "Stage '%s': pulando %s (já OK em status)." "$stage" "$spec"
                return 0
                ;;
            FAIL)
                adm_log_stage "Stage '%s': %s já falhou antes; tentando novamente." "$stage" "$spec"
                ;;
            none)
                : ;;
        esac
    fi

    adm_log_stage "Stage '%s': construindo e instalando pacote %s..." "$stage" "$spec"

    # Para cross/temp/stage2/base usamos mesma função – que chama build + install
    if ! adm_pkg_install_single "$category" "$pkg" "auto"; then
        adm_log_stage "Stage '%s': FALHA ao processar %s." "$stage" "$spec"
        adm_stage_pkg_status_set "$stage" "$spec" "FAIL" || :
        return 1
    fi

    adm_stage_pkg_status_set "$stage" "$spec" "OK" || :
    adm_log_stage "Stage '%s': sucesso em %s." "$stage" "$spec"
    return 0
}

###############################################################################
# Execução de um stage inteiro
###############################################################################

adm_stage_run() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_stage_run requer 1 argumento: STAGE"
        return 1
    fi
    local stage="$1"
    adm_stages__validate_stage_name "$stage" || return 1

    # Carrega lista de pacotes
    adm_stage_load_packages "$stage" || return 1

    adm_log_stage "=== INÍCIO DO STAGE '%s' (pacotes=%d, force=%s) ===" \
        "$stage" "${#ADM_STAGE_PKGS[@]}" "${ADM_STAGE_FORCE:-0}"

    # Aplica env
    adm_stage_apply_env "$stage" || return 1

    if ! adm_require_root; then
        adm_log_error "Stage '%s' requer root; abortando." "$stage"
        return 1
    fi

    local spec
    local failed=0

    for spec in "${ADM_STAGE_PKGS[@]}"; do
        if ! adm_stage_run_pkg "$stage" "$spec"; then
            adm_log_stage "Stage '%s': erro ao processar pacote %s." "$stage" "$spec"
            failed=1
            # Não abortamos o stage inteiro; continuamos, mas registramos.
        fi
    done

    if [ $failed -ne 0 ]; then
        adm_log_stage "=== STAGE '%s' concluído com FALHAS. Veja status em %s ===" \
            "$stage" "$(adm_stages__status_file "$stage")"
        return 1
    fi

    adm_log_stage "=== STAGE '%s' concluído com sucesso. ===" "$stage"
    return 0
}

###############################################################################
# Execução de vários stages em sequência
###############################################################################

# Uso:
#   adm_stages_run_sequence cross temp stage2 base
#   adm_stages_run_sequence   → usa ordem padrão ADM_STAGES_ORDER
adm_stages_run_sequence() {
    local stages=()
    if [ $# -eq 0 ]; then
        stages=("${ADM_STAGES_ORDER[@]}")
    else
        stages=("$@")
    fi

    local s
    local failed=0

    adm_log_stage "=== Iniciando sequência de stages: %s ===" "${stages[*]}"

    for s in "${stages[@]}"; do
        adm_stages__validate_stage_name "$s" || return 1
        if ! adm_stage_run "$s"; then
            adm_log_stage "Sequência interrompida: stage '%s' teve falhas." "$s"
            failed=1
            break
        fi
    done

    if [ $failed -ne 0 ]; then
        adm_log_stage "Sequência de stages concluída com falhas."
        return 1
    fi

    adm_log_stage "Sequência de stages concluída com sucesso."
    return 0
}

###############################################################################
# Listagem de stages e info
###############################################################################

adm_stages_list() {
    local s desc
    printf "stage\tprofile\tuse_chroot\tinstall_root\n"
    for s in "${ADM_STAGES_ORDER[@]}"; do
        desc="$(adm_stage_attr_get "$s" "DESC" 2>/dev/null || echo '')"
        local profile use_chroot install_root
        profile="$(adm_stage_attr_get "$s" "PROFILE" 2>/dev/null || echo '?')"
        use_chroot="$(adm_stage_attr_get "$s" "USE_CHROOT" 2>/dev/null || echo '?')"
        install_root="$(adm_stage_attr_get "$s" "INSTALL_ROOT" 2>/dev/null || echo '?')"
        printf "%s\t%s\t%s\t%s\n" "$s" "$profile" "$use_chroot" "$install_root"
        [ -n "$desc" ] && printf "  -> %s\n" "$desc"
    done
    return 0
}

###############################################################################
# Inicialização
###############################################################################

adm_stages_init() {
    adm_log_debug "Subsistema de estágios (stages.sh) carregado. Stages padrão: %s" "${ADM_STAGES_ORDER[*]}"
}

adm_stages_init
