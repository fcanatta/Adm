#!/usr/bin/env bash

# remove.sh — Remoção EXTREMA do ADM
#
# Modos:
#   adm remove <pkg>
#   adm remove <pkg> --keep-config
#   adm remove <pkg> --no-orphans
#
# Integração:
#   - ui.sh       → adm_ui_log_*, adm_ui_set_context
#   - db.sh       → adm_db_read_meta, adm_db_list_files, adm_db_remove_record
#   - package.sh  → nenhum uso direto (remover é por DB/FS)
#   - metafile.sh → opcional para hooks
#
# Nenhum erro silencioso / rollback para arquivos críticos.

ADM_ROOT="/usr/src/adm"
ADM_SCRIPTS="$ADM_ROOT/scripts"
ADM_BACKUP="$ADM_ROOT/backup/remove"
UI_OK=0
REMOVE_KEEP_CONFIG=0
REMOVE_CLEAN_ORPHANS=1
PKG_NAME=""

# ------------------------------------
# Carregar módulos
# ------------------------------------
load_module() {
    local f="$1"
    if [ -r "$ADM_SCRIPTS/$f" ]; then
        # shellcheck source=...
        . "$ADM_SCRIPTS/$f"
        return 0
    fi
    return 1
}

load_module "ui.sh"  && UI_OK=1
load_module "db.sh"
load_module "metafile.sh"

# ------------------------------------
# Logs
# ------------------------------------
log_info()  { [ "$UI_OK" -eq 1 ] && adm_ui_log_info  "$*" || printf '[INFO] %s\n' "$*"; }
log_warn()  { [ "$UI_OK" -eq 1 ] && adm_ui_log_warn  "$*" || printf '[WARN] %s\n' "$*"; }
log_error() { [ "$UI_OK" -eq 1 ] && adm_ui_log_error "$*" || printf '[ERROR] %s\n' "$*"; }

die() { log_error "$@"; exit 1; }

_timestamp() { date +"%Y%m%d-%H%M%S"; }

# ------------------------------------
# Hooks de remoção
# ------------------------------------
_find_pkg_repo_dir() {
    local pkg="$1"
    find "$ADM_ROOT/repo" -type f -path "*/$pkg/metafile" 2>/dev/null | head -n1 | xargs -r dirname
}

run_hook_pre_remove() {
    local pkg="$1"
    local d="$(_find_pkg_repo_dir "$pkg")"
    [ -z "$d" ] && return 0

    if [ -x "$d/hooks/pre_remove" ]; then
        log_info "Executando hook pre_remove para $pkg"
        "$d/hooks/pre_remove" "$pkg" || die "Falha no pre_remove hook de $pkg"
    fi
}

run_hook_post_remove() {
    local pkg="$1"
    local d="$(_find_pkg_repo_dir "$pkg")"
    [ -z "$d" ] && return 0

    if [ -x "$d/hooks/post_remove" ]; then
        log_info "Executando hook post_remove para $pkg"
        "$d/hooks/post_remove" "$pkg" || die "Falha no post_remove hook de $pkg"
    fi
}

# ------------------------------------
# Verificar se pacote existe no DB
# ------------------------------------
ensure_pkg_installed() {
    local pkg="$1"
    adm_db_init || die "DB não pôde ser inicializado"

    if ! adm_db_read_meta "$pkg"; then
        die "Pacote '$pkg' não está instalado ou não existe no DB"
    fi
}

# ------------------------------------
# Backup de arquivos antes de remover
# ------------------------------------
backup_file_for_pkg() {
    local pkg="$1"
    local file="$2"

    local ts="$(_timestamp)"
    local dst="$ADM_BACKUP/$pkg/$ts/$pkg"
    mkdir -p "$dst" 2>/dev/null || true

    local rel="${file#/}"
    mkdir -p "$dst/$(dirname "$rel")" 2>/dev/null || true

    cp -a "$file" "$dst/$rel" 2>/dev/null || true
}

# ------------------------------------
# Remover arquivos (com segurança)
# ------------------------------------
remove_files_of_pkg() {
    local pkg="$1"

    local files
    files="$(adm_db_list_files "$pkg" 2>/dev/null || true)"

    if [ -z "$files" ]; then
        log_warn "Nenhum arquivo registrado para $pkg — removendo registro apenas"
        return 0
    fi

    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        [ "$f" = "/" ] && continue

        if [ "$REMOVE_KEEP_CONFIG" -eq 1 ] && [[ "$f" =~ \.conf$ ]]; then
            log_info "Preservando arquivo de configuração: $f"
            continue
        fi

        if [ -e "$f" ]; then
            backup_file_for_pkg "$pkg" "$f"
            log_info "Removendo: $f"
            rm -rf "$f" 2>/dev/null || log_warn "Não foi possível remover $f"
        fi
    done <<< "$files"
}

# ------------------------------------
# Verificação de órfãos
# ------------------------------------
remove_orphans() {
    [ "$REMOVE_CLEAN_ORPHANS" -eq 0 ] && return 0

    if ! declare -F adm_db_list_orphans >/dev/null 2>&1; then
        log_warn "db.sh não possui adm_db_list_orphans — não limpando órfãos"
        return 0
    fi

    local orphans
    orphans="$(adm_db_list_orphans 2>/dev/null || true)"

    [ -z "$orphans" ] && return 0

    log_info "Removendo dependências órfãs:"
    local o
    for o in $orphans; do
        printf '  • %s\n' "$o"
    done

    for o in $orphans; do
        log_info "Removendo órfão: $o"
        # chamada recursiva controlada
        REMOVE_CLEAN_ORPHANS=0 "$0" "$o" --no-orphans >/dev/null 2>&1
    done
}
# ------------------------------------
# Remover registro no DB
# ------------------------------------
remove_db_record() {
    local pkg="$1"

    if ! declare -F adm_db_remove_record >/dev/null 2>&1; then
        die "db.sh não implementa adm_db_remove_record — não é possível remover registro"
    fi

    log_info "Removendo registro do DB para $pkg"
    adm_db_remove_record "$pkg" || die "Falha ao remover registro do pacote $pkg"
}

# ------------------------------------
# Fluxo principal de remoção
# ------------------------------------
remove_main() {
    local pkg="$1"

    if [ "$UI_OK" -eq 1 ]; then
        adm_ui_set_context "remove" "$pkg"
        adm_ui_set_log_file "remove" "$pkg" || true
    fi

    ensure_pkg_installed "$pkg"

    run_hook_pre_remove "$pkg"

    remove_files_of_pkg "$pkg"

    remove_db_record "$pkg"

    run_hook_post_remove "$pkg"

    remove_orphans

    log_info "Remoção concluída para $pkg"
    return 0
}

# ------------------------------------
# CLI
# ------------------------------------
print_help() {
    cat <<EOF
Uso:
  adm remove <pacote> [opções]

Opções:
  --keep-config    Preserva arquivos *.conf
  --no-orphans     Não remove dependências órfãs

EOF
}

CMD="$1"
shift || true

case "$CMD" in
    remove)
        for a in "$@"; do
            case "$a" in
                --keep-config) REMOVE_KEEP_CONFIG=1 ;;
                --no-orphans)  REMOVE_CLEAN_ORPHANS=0 ;;
                *) PKG_NAME="$a" ;;
            esac
        done
        [ -z "$PKG_NAME" ] && print_help && exit 1
        remove_main "$PKG_NAME"
        ;;
    *)
        print_help
        exit 1
        ;;
esac
