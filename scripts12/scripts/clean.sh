#!/usr/bin/env bash
# clean.sh – Limpeza inteligente do sistema ADM
#
# Tudo que é limpo fica DENTRO de /usr/src/adm:
#
#   /usr/src/adm/build      → builds temporários
#   /usr/src/adm/distfiles  → fontes baixadas
#   /usr/src/adm/chroot     → chroots de build
#   /usr/src/adm/logs       → logs
#   /usr/src/adm/packages   → pacotes gerados
#   /usr/src/adm/update     → metafiles/artefatos de update
#
# Cuidados:
#   - Nenhum erro silencioso
#   - rm -rf só em paths verificados e sob /usr/src/adm
#   - dry-run para simular antes de apagar
#
# Funções principais:
#   adm_clean_init
#   adm_clean_builds
#   adm_clean_distfiles
#   adm_clean_chroots
#   adm_clean_logs
#   adm_clean_packages
#   adm_clean_update
#   adm_clean_all_quick
#   adm_clean_all_deep
#
# Pode ser usado tanto como "sourced" quanto como script direto:
#   ./clean.sh builds
#   ./clean.sh all-deep --dry-run

ADM_ROOT="/usr/src/adm"
ADM_BUILD_DIR="$ADM_ROOT/build"
ADM_DISTFILES_DIR="$ADM_ROOT/distfiles"
ADM_CHROOT_DIR="$ADM_ROOT/chroot"
ADM_LOG_DIR="$ADM_ROOT/logs"
ADM_PACKAGES_DIR="$ADM_ROOT/packages"
ADM_UPDATE_DIR="$ADM_ROOT/update"

# dry-run global (0 = executa, 1 = apenas mostra)
ADM_CLEAN_DRY_RUN="${ADM_CLEAN_DRY_RUN:-0}"

_CLEAN_HAVE_UI=0

if declare -F adm_ui_log_info >/dev/null 2>&1; then
    _CLEAN_HAVE_UI=1
fi

_clean_log() {
    local lvl="$1"; shift || true
    local msg="$*"
    if [ "$_CLEAN_HAVE_UI" -eq 1 ]; then
        case "$lvl" in
            INFO)  adm_ui_log_info  "$msg" ;;
            WARN)  adm_ui_log_warn  "$msg" ;;
            ERROR) adm_ui_log_error "$msg" ;;
            DEBUG) adm_ui_log_info  "[DEBUG] $msg" ;;
            *)     adm_ui_log_info  "$msg" ;;
        esac
    else
        printf 'clean[%s]: %s\n' "$lvl" "$msg" >&2
    fi
}

_clean_fail() {
    _clean_log ERROR "$*"
    return 1
}

_clean_trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# --------------------------------
# Verificação de segurança de path
# --------------------------------
_clean_realpath() {
    # realpath com fallback
    local p="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath -m "$p"
    elif command -v readlink >/dev/null 2>&1; then
        readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
    else
        printf '%s\n' "$p"
    fi
}

_clean_ensure_under_root() {
    # Garante que o path está dentro de ADM_ROOT.
    # Uso:
    #   _clean_ensure_under_root "/usr/src/adm/build"
    local p="$(_clean_realpath "$1")"
    local root="$(_clean_realpath "$ADM_ROOT")"

    if [ -z "$p" ] || [ -z "$root" ]; then
        _clean_fail "Falha ao resolver caminho seguro (path ou root vazio)"
        return 1
    fi

    case "$p" in
        "$root" | "$root"/*)
            return 0
            ;;
        *)
            _clean_fail "Operação de limpeza negada: caminho '$p' não está sob '$root'"
            return 1
            ;;
    esac
}

# --------------------------------
# Execução segura de rm -rf / find
# --------------------------------
_clean_rm_rf() {
    # Uso:
    #   _clean_rm_rf "/usr/src/adm/build"
    local path="$1"
    [ -z "$path" ] && _clean_fail "_clean_rm_rf: path vazio" && return 1

    _clean_ensure_under_root "$path" || return 1

    if [ "$ADM_CLEAN_DRY_RUN" = "1" ]; then
        _clean_log INFO "[dry-run] rm -rf \"$path\""
        return 0
    fi

    if [ -e "$path" ]; then
        rm -rf -- "$path" 2>/dev/null || {
            _clean_fail "Falha ao remover '$path'"
            return 1
        }
        _clean_log INFO "Removido: $path"
    else
        _clean_log DEBUG "Nada a remover (não existe): $path"
    fi
    return 0
}

_clean_find_delete_older_than() {
    # Apaga dentro de um diretório arquivos/dirs com idade > N dias
    # Uso:
    #   _clean_find_delete_older_than DIR DIAS
    local dir="$1"
    local days="$2"

    if [ -z "$dir" ] || [ -z "$days" ]; then
        _clean_fail "_clean_find_delete_older_than: uso incorreto (dir/days vazios)"
        return 1
    fi

    _clean_ensure_under_root "$dir" || return 1

    if [ ! -d "$dir" ]; then
        _clean_log DEBUG "Diretório não existe, nada a limpar: $dir"
        return 0
    fi

    local find_cmd=(find "$dir" -mindepth 1 -mtime "+$days" -print)
    local to_delete
    to_delete="$("${find_cmd[@]}" 2>/dev/null)"

    if [ -z "$to_delete" ]; then
        _clean_log INFO "Nenhum item mais antigo que $days dias em $dir"
        return 0
    fi

    _clean_log INFO "Itens mais antigos que $days dias em $dir:"
    printf '%s\n' "$to_delete" >&2

    if [ "$ADM_CLEAN_DRY_RUN" = "1" ]; then
        _clean_log INFO "[dry-run] não removendo arquivos listados acima"
        return 0
    fi

    # Remove via while para evitar problemas com espaços
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        _clean_rm_rf "$path" || return 1
    done <<< "$to_delete"

    return 0
}

# --------------------------------
# Inicialização do sistema de limpeza
# --------------------------------
adm_clean_init() {
    # Garante que ADM_ROOT e subpastas são coerentes
    if [ ! -d "$ADM_ROOT" ]; then
        _clean_fail "ADM_ROOT não existe: $ADM_ROOT"
        return 1
    fi

    # Apenas loga se subdirs não existem; não é erro
    [ -d "$ADM_BUILD_DIR" ]     || _clean_log DEBUG "BUILD_DIR ausente: $ADM_BUILD_DIR"
    [ -d "$ADM_DISTFILES_DIR" ] || _clean_log DEBUG "DISTFILES_DIR ausente: $ADM_DISTFILES_DIR"
    [ -d "$ADM_CHROOT_DIR" ]    || _clean_log DEBUG "CHROOT_DIR ausente: $ADM_CHROOT_DIR"
    [ -d "$ADM_LOG_DIR" ]       || _clean_log DEBUG "LOG_DIR ausente: $ADM_LOG_DIR"
    [ -d "$ADM_PACKAGES_DIR" ]  || _clean_log DEBUG "PACKAGES_DIR ausente: $ADM_PACKAGES_DIR"
    [ -d "$ADM_UPDATE_DIR" ]    || _clean_log DEBUG "UPDATE_DIR ausente: $ADM_UPDATE_DIR"

    _clean_log INFO "clean.sh inicializado (ADM_ROOT=$ADM_ROOT, dry-run=$ADM_CLEAN_DRY_RUN)"
    return 0
}
# --------------------------------
# Limpar builds (sempre seguro)
# --------------------------------
adm_clean_builds() {
    # Remove TODO o conteúdo de /usr/src/adm/build
    adm_clean_init || return 1

    if [ ! -d "$ADM_BUILD_DIR" ]; then
        _clean_log INFO "Nenhum diretório de build encontrado em $ADM_BUILD_DIR"
        return 0
    fi

    _clean_log INFO "Limpando builds em $ADM_BUILD_DIR"
    _clean_rm_rf "$ADM_BUILD_DIR" || return 1
    # recria diretório vazio
    if [ "$ADM_CLEAN_DRY_RUN" = "0" ]; then
        mkdir -p "$ADM_BUILD_DIR" 2>/dev/null || _clean_fail "Falha ao recriar $ADM_BUILD_DIR"
    fi
    return 0
}

# --------------------------------
# Limpar distfiles (opcionalmente por idade)
# --------------------------------
adm_clean_distfiles() {
    # Uso:
    #   adm_clean_distfiles              → nada (só info)
    #   adm_clean_distfiles all          → remove tudo em distfiles
    #   adm_clean_distfiles older-than N → remove arquivos com mais de N dias
    adm_clean_init || return 1

    local mode="${1:-}"
    local days="${2:-}"

    if [ ! -d "$ADM_DISTFILES_DIR" ]; then
        _clean_log INFO "Diretório de distfiles não existe: $ADM_DISTFILES_DIR (nada a limpar)"
        return 0
    fi

    case "$mode" in
        all)
            _clean_log INFO "Limpando TODOS os distfiles em $ADM_DISTFILES_DIR"
            _clean_rm_rf "$ADM_DISTFILES_DIR" || return 1
            if [ "$ADM_CLEAN_DRY_RUN" = "0" ]; then
                mkdir -p "$ADM_DISTFILES_DIR" 2>/dev/null || _clean_fail "Falha ao recriar $ADM_DISTFILES_DIR"
            fi
            ;;
        older-than)
            if [ -z "$days" ]; then
                _clean_fail "adm_clean_distfiles older-than: informe número de dias"
                return 1
            fi
            _clean_log INFO "Limpando distfiles com mais de $days dias em $ADM_DISTFILES_DIR"
            _clean_find_delete_older_than "$ADM_DISTFILES_DIR" "$days" || return 1
            ;;
        ""|*)
            _clean_log INFO "adm_clean_distfiles: especifique 'all' ou 'older-than N'"
            return 1
            ;;
    esac

    return 0
}

# --------------------------------
# Limpar chroots
# --------------------------------
adm_clean_chroots() {
    # Uso:
    #   adm_clean_chroots all
    #   adm_clean_chroots stale (no futuro pode checar mountpoints, etc.)
    adm_clean_init || return 1

    local mode="${1:-all}"

    if [ ! -d "$ADM_CHROOT_DIR" ]; then
        _clean_log INFO "Diretório de chroots não existe: $ADM_CHROOT_DIR"
        return 0
    fi

    case "$mode" in
        all)
            _clean_log INFO "Limpando TODOS os chroots em $ADM_CHROOT_DIR (certifique-se de que nenhum está montado)"
            # Poderíamos adicionar checagens de mounts futuramente
            _clean_rm_rf "$ADM_CHROOT_DIR" || return 1
            if [ "$ADM_CLEAN_DRY_RUN" = "0" ]; then
                mkdir -p "$ADM_CHROOT_DIR" 2>/dev/null || _clean_fail "Falha ao recriar $ADM_CHROOT_DIR"
            fi
            ;;
        stale)
            # Hook futuro para limpeza mais inteligente
            _clean_log WARN "Modo 'stale' ainda não implementado; usando 'all'"
            adm_clean_chroots all
            ;;
        *)
            _clean_fail "adm_clean_chroots: modo inválido '$mode' (use 'all' ou 'stale')"
            return 1
            ;;
    esac

    return 0
}

# --------------------------------
# Limpar logs
# --------------------------------
adm_clean_logs() {
    # Uso:
    #   adm_clean_logs all
    #   adm_clean_logs older-than N
    adm_clean_init || return 1

    local mode="${1:-}"
    local days="${2:-}"

    if [ ! -d "$ADM_LOG_DIR" ]; then
        _clean_log INFO "Diretório de logs não existe: $ADM_LOG_DIR"
        return 0
    fi

    case "$mode" in
        all)
            _clean_log INFO "Limpando TODOS os logs em $ADM_LOG_DIR"
            _clean_rm_rf "$ADM_LOG_DIR" || return 1
            if [ "$ADM_CLEAN_DRY_RUN" = "0" ]; then
                mkdir -p "$ADM_LOG_DIR" 2>/dev/null || _clean_fail "Falha ao recriar $ADM_LOG_DIR"
            fi
            ;;
        older-than)
            if [ -z "$days" ]; then
                _clean_fail "adm_clean_logs older-than: informe número de dias"
                return 1
            fi
            _clean_log INFO "Limpando logs com mais de $days dias em $ADM_LOG_DIR"
            _clean_find_delete_older_than "$ADM_LOG_DIR" "$days" || return 1
            ;;
        ""|*)
            _clean_fail "adm_clean_logs: especifique 'all' ou 'older-than N'"
            return 1
            ;;
    esac

    return 0
}

# --------------------------------
# Limpar pacotes gerados
# --------------------------------
adm_clean_packages() {
    # Uso:
    #   adm_clean_packages all
    #   adm_clean_packages older-than N
    adm_clean_init || return 1

    local mode="${1:-}"
    local days="${2:-}"

    if [ ! -d "$ADM_PACKAGES_DIR" ]; then
        _clean_log INFO "Diretório de packages não existe: $ADM_PACKAGES_DIR"
        return 0
    fi

    case "$mode" in
        all)
            _clean_log INFO "Limpando TODOS os pacotes em $ADM_PACKAGES_DIR"
            _clean_rm_rf "$ADM_PACKAGES_DIR" || return 1
            if [ "$ADM_CLEAN_DRY_RUN" = "0" ]; then
                mkdir -p "$ADM_PACKAGES_DIR" 2>/dev/null || _clean_fail "Falha ao recriar $ADM_PACKAGES_DIR"
            fi
            ;;
        older-than)
            if [ -z "$days" ]; then
                _clean_fail "adm_clean_packages older-than: informe número de dias"
                return 1
            fi
            _clean_log INFO "Limpando packages com mais de $days dias em $ADM_PACKAGES_DIR"
            _clean_find_delete_older_than "$ADM_PACKAGES_DIR" "$days" || return 1
            ;;
        ""|*)
            _clean_fail "adm_clean_packages: especifique 'all' ou 'older-than N'"
            return 1
            ;;
    esac

    return 0
}

# --------------------------------
# Limpar update cache
# --------------------------------
adm_clean_update() {
    # Uso:
    #   adm_clean_update all
    #   adm_clean_update older-than N
    adm_clean_init || return 1

    local mode="${1:-}"
    local days="${2:-}"

    if [ ! -d "$ADM_UPDATE_DIR" ]; then
        _clean_log INFO "Diretório de update não existe: $ADM_UPDATE_DIR"
        return 0
    fi

    case "$mode" in
        all)
            _clean_log INFO "Limpando TODO o cache de update em $ADM_UPDATE_DIR"
            _clean_rm_rf "$ADM_UPDATE_DIR" || return 1
            if [ "$ADM_CLEAN_DRY_RUN" = "0" ]; then
                mkdir -p "$ADM_UPDATE_DIR" 2>/dev/null || _clean_fail "Falha ao recriar $ADM_UPDATE_DIR"
            fi
            ;;
        older-than)
            if [ -z "$days" ]; then
                _clean_fail "adm_clean_update older-than: informe número de dias"
                return 1
            fi
            _clean_log INFO "Limpando update cache com mais de $days dias em $ADM_UPDATE_DIR"
            _clean_find_delete_older_than "$ADM_UPDATE_DIR" "$days" || return 1
            ;;
        ""|*)
            _clean_fail "adm_clean_update: especifique 'all' ou 'older-than N'"
            return 1
            ;;
    esac

    return 0
}

# --------------------------------
# Limpezas compostas
# --------------------------------
adm_clean_all_quick() {
    # Limpeza rápida: builds + logs antigos + chroots
    adm_clean_init || return 1
    adm_clean_builds || return 1
    adm_clean_logs older-than 7 || return 1
    adm_clean_chroots all || return 1
    _clean_log INFO "Limpeza rápida concluída"
    return 0
}

adm_clean_all_deep() {
    # Limpeza profunda: tudo que é temporário/cache
    adm_clean_init || return 1
    adm_clean_builds || return 1
    adm_clean_distfiles all || return 1
    adm_clean_chroots all || return 1
    adm_clean_logs all || return 1
    adm_clean_packages all || return 1
    adm_clean_update all || return 1
    _clean_log INFO "Limpeza profunda concluída"
    return 0
}

# --------------------------------
# Modo CLI (se chamado diretamente)
# --------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Exemplo de uso:
    #   ./clean.sh builds
    #   ./clean.sh distfiles all
    #   ./clean.sh distfiles older-than 30
    #   ./clean.sh all-quick --dry-run
    #   ./clean.sh all-deep

    # argumento especial --dry-run em qualquer posição
    args=()
    for a in "$@"; do
        if [ "$a" = "--dry-run" ]; then
            ADM_CLEAN_DRY_RUN=1
        else
            args+=("$a")
        fi
    done
    set -- "${args[@]}"

    cmd="${1:-help}"
    shift || true

    case "$cmd" in
        help|-h|--help)
            cat << EOF
Uso: clean.sh [--dry-run] comando [opções]

Comandos:
  builds
      Limpa todos os builds em $ADM_BUILD_DIR

  distfiles all
      Remove todos os distfiles em $ADM_DISTFILES_DIR

  distfiles older-than N
      Remove distfiles com mais de N dias

  chroots [all|stale]
      Limpa chroots (por enquanto apenas 'all')

  logs all
      Remove todos os logs

  logs older-than N
      Remove logs com mais de N dias

  packages all|older-than N
      Limpa pacotes gerados

  update all|older-than N
      Limpa cache de update

  all-quick
      Limpeza rápida: builds + logs antigos + chroots

  all-deep
      Limpeza profunda: builds + distfiles + chroots + logs + packages + update

Opções:
  --dry-run
      Não remove nada, apenas mostra o que seria feito
EOF
            ;;
        builds)
            adm_clean_builds || exit 1
            ;;
        distfiles)
            adm_clean_distfiles "$@" || exit 1
            ;;
        chroots)
            adm_clean_chroots "$@" || exit 1
            ;;
        logs)
            adm_clean_logs "$@" || exit 1
            ;;
        packages)
            adm_clean_packages "$@" || exit 1
            ;;
        update)
            adm_clean_update "$@" || exit 1
            ;;
        all-quick)
            adm_clean_all_quick || exit 1
            ;;
        all-deep)
            adm_clean_all_deep || exit 1
            ;;
        *)
            printf 'Comando desconhecido: %s\n' "$cmd" >&2
            exit 1
            ;;
    esac
fi
