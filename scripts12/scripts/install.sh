#!/usr/bin/env bash

# install.sh – Instalador EXTREMO do ADM
#
# Modos:
#   adm install <pkg> [--no-deps]
#   adm install-bin <pkg> [--no-deps]
#   adm install <arquivo.pkg|.deb|.rpm>
#
# Integração:
#   - metafile.sh  -> adm_meta_load / MF_*
#   - source.sh    -> adm_source_prepare_from_meta (chamado dentro do build_core)
#   - build_core.sh-> adm_build_core_from_meta (chroot seguro + DESTDIR=/dest)
#   - package.sh   -> adm_pkg_from_destdir, adm_pkg_install_file, reempacotar .deb/.rpm
#   - db.sh        -> registro no banco
#   - ui.sh        -> logs e contexto bonitinho, se disponível
#
# Este script NÃO usa set -e para não quebrar chamadores.

ADM_ROOT="/usr/src/adm"
ADM_SCRIPTS="$ADM_ROOT/scripts"
ADM_REPO="$ADM_ROOT/repo"
ADM_PKG_CACHE="$ADM_ROOT/packages"
ADM_BACKUP="$ADM_ROOT/backup"
ADM_BUILD="$ADM_ROOT/build"

INSTALL_NO_DEPS=0
INSTALL_BIN=0
INSTALL_FILE=""
INSTALL_NAME=""
UI_OK=0

# -----------------------------
# Carregar módulos
# -----------------------------
if [ -r "$ADM_SCRIPTS/ui.sh" ]; then
    # shellcheck source=/usr/src/adm/scripts/ui.sh
    . "$ADM_SCRIPTS/ui.sh"
    UI_OK=1
fi
if [ -r "$ADM_SCRIPTS/db.sh" ]; then
    # shellcheck source=/usr/src/adm/scripts/db.sh
    . "$ADM_SCRIPTS/db.sh"
fi
if [ -r "$ADM_SCRIPTS/metafile.sh" ]; then
    # shellcheck source=/usr/src/adm/scripts/metafile.sh
    . "$ADM_SCRIPTS/metafile.sh"
fi
if [ -r "$ADM_SCRIPTS/source.sh" ]; then
    # shellcheck source=/usr/src/adm/scripts/source.sh
    . "$ADM_SCRIPTS/source.sh"
fi
if [ -r "$ADM_SCRIPTS/build_core.sh" ]; then
    # shellcheck source=/usr/src/adm/scripts/build_core.sh
    . "$ADM_SCRIPTS/build_core.sh"
fi
if [ -r "$ADM_SCRIPTS/package.sh" ]; then
    # shellcheck source=/usr/src/adm/scripts/package.sh
    . "$ADM_SCRIPTS/package.sh"
fi
if [ -r "$ADM_SCRIPTS/profile.sh" ]; then
    # shellcheck source=/usr/src/adm/scripts/profile.sh
    . "$ADM_SCRIPTS/profile.sh"
fi

# -----------------------------
# Logs básicos
# -----------------------------
log_info()  { [ "$UI_OK" -eq 1 ] && adm_ui_log_info  "$*" || printf '[INFO] %s\n'  "$*" >&2; }
log_warn()  { [ "$UI_OK" -eq 1 ] && adm_ui_log_warn  "$*" || printf '[WARN] %s\n'  "$*" >&2; }
log_error() { [ "$UI_OK" -eq 1 ] && adm_ui_log_error "$*" || printf '[ERROR] %s\n' "$*" >&2; }

die() {
    log_error "$@"
    exit 1
}

_trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

_timestamp() {
    date +"%Y%m%d-%H%M%S"
}

# -----------------------------
# Backup de arquivos
# -----------------------------
backup_local() {
    local file="$1"
    local ts; ts="$(_timestamp)"
    [ -e "$file" ] || return 0
    cp -a "$file" "${file}.adm-bak-$ts" 2>/dev/null || true
}

backup_global() {
    local pkg="$1"
    local file="$2"
    local ts; ts="$(_timestamp)"
    local dst="$ADM_BACKUP/$pkg/$ts"

    mkdir -p "$dst" 2>/dev/null || true
    [ -e "$file" ] || return 0

    local rel="${file#/}"
    mkdir -p "$dst/$(dirname "$rel")" 2>/dev/null || true
    cp -a "$file" "$dst/$rel" 2>/dev/null || true
}

install_backup() {
    local pkg="$1"
    local file="$2"
    backup_local "$file"
    backup_global "$pkg" "$file"
}

# -----------------------------
# Tipo de arquivo (.pkg/.deb/.rpm)
# -----------------------------
detect_pkg_file_type() {
    local f="$1"
    case "$f" in
        *.pkg) echo "adm" ;;
        *.deb) echo "deb" ;;
        *.rpm) echo "rpm" ;;
        *)     echo "unknown" ;;
    esac
}

# -----------------------------
# Localizar metafile no repo
# -----------------------------
load_metafile_for() {
    local name="$1"
    local meta

    meta=$(find "$ADM_REPO" -type f -path "*/$name/metafile" 2>/dev/null | head -n1)
    [ -z "$meta" ] && return 1

    if ! adm_meta_load "$meta"; then
        return 1
    fi

    # valida, se a função existir
    if declare -F adm_meta_validate >/dev/null 2>&1; then
        adm_meta_validate || return 1
    fi
    return 0
}

# compat: alguns trechos antigos esperavam load_metafile
load_metafile() {
    load_metafile_for "$1"
}

# -----------------------------
# Hooks pre/post_install
# -----------------------------
_find_pkg_dir_in_repo() {
    local name="$1"
    find "$ADM_REPO" -type f -path "*/$name/metafile" 2>/dev/null | head -n1 | xargs -r dirname
}

run_hooks_pre() {
    local name="$1"
    local dir
    dir="$(_find_pkg_dir_in_repo "$name")"
    [ -z "$dir" ] && return 0

    if [ -x "$dir/hooks/pre_install" ]; then
        log_info "Executando pre_install hook para $name"
        "$dir/hooks/pre_install" "$name" || die "Falha no pre_install hook de $name"
    fi
}

run_hooks_post() {
    local name="$1"
    local dir
    dir="$(_find_pkg_dir_in_repo "$name")"
    [ -z "$dir" ] && return 0

    if [ -x "$dir/hooks/post_install" ]; then
        log_info "Executando post_install hook para $name"
        "$dir/hooks/post_install" "$name" || die "Falha no post_install hook de $name"
    fi
}

# -----------------------------
# Remover versões antigas (modo single-version)
# -----------------------------
remove_old_versions() {
    local name="$1"

    if ! declare -F adm_db_init >/dev/null 2>&1; then
        log_warn "db.sh não suporta adm_db_init; não removendo versões antigas de $name"
        return 0
    fi

    adm_db_init || return 0

    if ! declare -F adm_db_list_installed >/dev/null 2>&1; then
        log_warn "adm_db_list_installed não encontrado; não removendo versões antigas de $name"
        return 0
    fi

    if ! declare -F adm_db_unregister >/dev/null 2>&1; then
        log_warn "adm_db_unregister não encontrado; não removendo versões antigas de $name"
        return 0
    fi

    local line
    adm_db_list_installed 2>/dev/null | grep "^$name " || true | while read -r line; do
        [ -z "$line" ] && continue
        # formato esperado: name version category ...
        local pkg ver
        pkg="$(echo "$line" | awk '{print $1"-"$2}')"
        ver="$(echo "$line" | awk '{print $2}')"
        log_info "Removendo registro de versão antiga de $name: $ver"
        adm_db_unregister "$pkg" 2>/dev/null || true
    done
}

# -----------------------------
# Instalação .pkg com backup de conflitos
# -----------------------------
install_pkg_file_secure() {
    local pkgfile="$1"

    if [ -z "$pkgfile" ]; then
        die "install_pkg_file_secure: arquivo .pkg não informado"
    fi
    if [ ! -f "$pkgfile" ]; then
        die "install_pkg_file_secure: arquivo não encontrado: $pkgfile"
    fi

    if ! declare -F _pkg_ensure_db >/dev/null 2>&1; then
        die "package.sh não parece carregado (_pkg_ensure_db ausente)"
    fi

    _pkg_ensure_db || die "Falha em _pkg_ensure_db"
    _pkg_check_tar_zstd || die "Falha em _pkg_check_tar_zstd"
    adm_db_init || die "Falha em adm_db_init"

    local stage
    stage="$(mktemp -d "$ADM_ROOT/build/.pkginst.XXXXXX" 2>/dev/null)" || die "Não foi possível criar diretório temporário para instalação"

    # Extrair .pkg inteiro para stage
    if ! _pkg_tar_extract_to_dir "$pkgfile" "$stage"; then
        rm -rf "$stage" 2>/dev/null || true
        die "Falha ao extrair pacote $pkgfile"
    fi

    # Ler manifest
    if ! _pkg_read_manifest_file "$stage"; then
        rm -rf "$stage" 2>/dev/null || true
        die "Falha ao ler manifest do pacote $pkgfile"
    fi

    # Ajustar arch se vazio
    if [ -z "$PKG_MAN_ARCH" ]; then
        PKG_MAN_ARCH="$(_pkg_detect_arch)"
    fi

    # Ler lista de arquivos
    local files_file="$stage/CONTROL/files"
    if [ ! -f "$files_file" ]; then
        rm -rf "$stage" 2>/dev/null || true
        die "Lista de arquivos não encontrada em $files_file"
    fi

    local files_rel
    files_rel="$(cat "$files_file" 2>/dev/null || true)"

    # Backup de conflitos (modo C: local + global) ANTES de extrair
    local f full
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        full="/$f"
        if [ -e "$full" ]; then
            install_backup "$PKG_MAN_NAME" "$full"
        fi
    done <<< "$files_rel"

    # Extrair arquivos para /
    (
        cd "$stage" || exit 1
        tar -cf - . --exclude CONTROL 2>/dev/null
    ) | tar -C / -xf - 2>/dev/null || {
        rm -rf "$stage" 2>/dev/null || true
        die "Falha ao extrair dados do pacote $pkgfile para /"
    }

    # Montar lista de arquivos com / inicial para DB
    local files_db=""
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        files_db="${files_db}/$f"$'\n'
    done <<< "$files_rel"

    # Registrar no DB
    local name="$PKG_MAN_NAME"
    local version="$PKG_MAN_VERSION"
    local category="$PKG_MAN_CATEGORY"
    local libc="$PKG_MAN_LIBC"
    local init="$PKG_MAN_INIT"
    local profile="$PKG_MAN_PROFILE"
    local target="$PKG_MAN_TARGET"
    local reason="$PKG_MAN_REASON"
    [ -z "$reason" ] && reason="manual"

    if ! adm_db_register_install \
        "$name" "$version" "$category" "$libc" "$init" "$profile" "$target" "$reason" \
        "$PKG_MAN_RUN_DEPS" "$PKG_MAN_BUILD_DEPS" "$PKG_MAN_OPT_DEPS" \
        "$files_db"
    then
        rm -rf "$stage" 2>/dev/null || true
        die "Falha ao registrar pacote '$name' no DB"
    fi

    log_info "Pacote instalado (com backup) e registrado: $name-$version (release=$PKG_MAN_RELEASE arch=$PKG_MAN_ARCH)"
    rm -rf "$stage" 2>/dev/null || true
    return 0
}
# -----------------------------
# Cache binário / deps binários
# -----------------------------
is_bin_pkg_available() {
    local name="$1"
    local p="$ADM_PKG_CACHE/$name"
    [ -d "$p" ] || return 1
    find "$p" -type f -name "$name-*.pkg" 2>/dev/null | head -n1
}

resolve_bin_dep() {
    local dep="$1"
    local file

    file="$(is_bin_pkg_available "$dep")"
    if [ -n "$file" ]; then
        log_info "Instalando dependência binária $dep a partir de $file"
        install_pkg_file_secure "$file"
        return 0
    fi

    return 1
}

# -----------------------------
# Resolver dependência via source (build_core novo)
# -----------------------------
resolve_dep_source() {
    local dep="$1"

    log_info "Resolvendo dependência via source: $dep"

    load_metafile_for "$dep" || die "Metafile não encontrado para dependência $dep"

    # build_core faz:
    #   - adm_source_prepare_from_meta
    #   - chroot seguro
    #   - DESTDIR em /usr/src/adm/build/<name>-<version>/dest
    if ! adm_build_core_from_meta; then
        die "Build da dependência $dep falhou"
    fi

    local dest="$ADM_BUILD/${MF_NAME}-${MF_VERSION}/dest"
    if [ ! -d "$dest" ]; then
        die "DESTDIR inexistente após build de $dep: $dest"
    fi

    # pacote binário só (build-only) e depois instalar com backup seguro
    local tmp_out
    tmp_out="$(mktemp "$ADM_ROOT/build/.dep_pkg_out.XXXXXX" 2>/dev/null)" || die "Não foi possível criar tmp para pacote de $dep"
    ADM_PKG_BUILD_ONLY=1 adm_pkg_from_destdir "$dest" >"$tmp_out" || {
        rm -f "$tmp_out" 2>/dev/null || true
        die "Falha ao empacotar dependência $dep a partir de $dest"
    }

    local pkgfile
    pkgfile="$(cat "$tmp_out" 2>/dev/null || true)"
    rm -f "$tmp_out" 2>/dev/null || true

    [ -z "$pkgfile" ] && die "adm_pkg_from_destdir não retornou caminho de pacote para $dep"
    [ -f "$pkgfile" ] || die "Pacote da dependência $dep não encontrado: $pkgfile"

    install_pkg_file_secure "$pkgfile"
}

# -----------------------------
# Resolver todas as dependências (run+build)
# -----------------------------
resolve_all_deps_full() {
    local name="$1"
    [ "$INSTALL_NO_DEPS" -eq 1 ] && return 0

    # MF_* já carregados para o pacote corrente
    local deps
    deps="$(_trim "${MF_RUN_DEPS:-} ${MF_BUILD_DEPS:-}")"

    [ -z "$deps" ] && return 0

    local d
    for d in $deps; do
        [ -z "$d" ] && continue
        log_info "Resolvendo dependência: $d"
        resolve_bin_dep "$d" || resolve_dep_source "$d"
    done
}

# -----------------------------
# Fluxo binário com fallback p/ source
# -----------------------------
install_bin_fallback() {
    local name="$1"

    local f
    f="$(is_bin_pkg_available "$name")"
    if [ -z "$f" ]; then
        log_info "Nenhum pacote binário encontrado para $name; caindo para build de source"
        return 1
    fi

    log_info "Encontrado pacote binário para $name: $f"

    # Ler manifest para descobrir deps do pacote binário
    local stage m tmp
    stage="$(mktemp -d "$ADM_ROOT/build/.bininspect.XXXXXX" 2>/dev/null)" || die "Falha ao criar stage para inspeção de binário"
    m="$stage/meta"

    mkdir -p "$m" 2>/dev/null || true
    if ! _pkg_tar_extract_to_dir "$f" "$m"; then
        rm -rf "$stage" 2>/dev/null || true
        die "Falha ao extrair binário para inspeção: $f"
    fi

    if ! _pkg_read_manifest_file "$m"; then
        rm -rf "$stage" 2>/dev/null || true
        die "Falha ao ler manifest do binário: $f"
    fi

    local all_deps
    all_deps="$(_trim "$PKG_MAN_RUN_DEPS")"

    local d
    for d in $all_deps; do
        [ -z "$d" ] && continue
        resolve_bin_dep "$d" || resolve_dep_source "$d"
    done

    rm -rf "$stage" 2>/dev/null || true

    install_pkg_file_secure "$f"
    return 0
}

# -----------------------------
# Fluxo de instalação via source (build_core novo)
# -----------------------------
install_source_full() {
    local name="$1"

    log_info "Instalando $name a partir de source (build_core)"

    load_metafile_for "$name" || die "Metafile de $name não encontrado"

    # Resolver deps com base no MF_* do pacote
    resolve_all_deps_full "$name"

    # Build extremo via chroot seguro
    if ! adm_build_core_from_meta; then
        die "Build de $name falhou via build_core"
    fi

    local dest="$ADM_BUILD/${MF_NAME}-${MF_VERSION}/dest"
    if [ ! -d "$dest" ]; then
        die "DESTDIR inexistente após build de $name: $dest"
    fi

    # Criar pacote com build-only e depois instalar com backup
    local tmp_out pkgfile
    tmp_out="$(mktemp "$ADM_ROOT/build/.pkgsrc_out.XXXXXX" 2>/dev/null)" || die "Não foi possível criar tmp para pacote de $name"
    ADM_PKG_BUILD_ONLY=1 adm_pkg_from_destdir "$dest" >"$tmp_out" || {
        rm -f "$tmp_out" 2>/dev/null || true
        die "Falha ao empacotar $name a partir de $dest"
    }

    pkgfile="$(cat "$tmp_out" 2>/dev/null || true)"
    rm -f "$tmp_out" 2>/dev/null || true

    [ -z "$pkgfile" ] && die "adm_pkg_from_destdir não retornou caminho de pacote para $name"
    [ -f "$pkgfile" ] || die "Pacote de $name não encontrado: $pkgfile"

    install_pkg_file_secure "$pkgfile"
}

# -----------------------------
# Instalar arquivo direto (.pkg/.deb/.rpm)
# -----------------------------
install_file_auto() {
    local file="$1"
    local t

    t="$(detect_pkg_file_type "$file")"
    case "$t" in
        adm)
            log_info "Instalando pacote ADM direto: $file"
            install_pkg_file_secure "$file"
            ;;
        deb)
            log_info "Reempacotando .deb via package.sh: $file"
            # adm_pkg_repack_deb já instala e registra usando adm_pkg_install_file
            adm_pkg_repack_deb "$file" || die "Falha ao reempacotar .deb: $file"
            ;;
        rpm)
            log_info "Reempacotando .rpm via package.sh: $file"
            adm_pkg_repack_rpm "$file" || die "Falha ao reempacotar .rpm: $file"
            ;;
        *)
            die "Arquivo desconhecido: $file (esperado .pkg, .deb ou .rpm)"
            ;;
    esac
}

# -----------------------------
# Fluxo principal por nome de pacote
# -----------------------------
install_main() {
    local name="$1"

    if [ "$UI_OK" -eq 1 ]; then
        adm_ui_set_context "install" "$name"
        adm_ui_set_log_file "install" "$name" || true
    fi

    run_hooks_pre "$name"
    remove_old_versions "$name"

    if [ "$INSTALL_BIN" -eq 1 ]; then
        install_bin_fallback "$name" && {
            run_hooks_post "$name"
            return 0
        }
        log_warn "Pacote binário de $name indisponível ou falhou; construindo a partir do source"
        install_source_full "$name"
        run_hooks_post "$name"
        return 0
    fi

    install_source_full "$name"
    run_hooks_post "$name"
}

install_from_pkg_or_source() {
    local arg="$1"

    if [ -f "$arg" ]; then
        install_file_auto "$arg"
        exit 0
    fi

    INSTALL_NAME="$arg"
    install_main "$INSTALL_NAME"
}

# -----------------------------
# Ajuda / CLI
# -----------------------------
print_help() {
    cat <<EOF
Usage:
  adm install <pkg> [--no-deps]
  adm install-bin <pkg> [--no-deps]
  adm install <arquivo.pkg|.deb|.rpm>

Opções:
  --no-deps   Não resolver dependências (apenas o pacote alvo)

EOF
}

CMD="$1"
shift || true

case "$CMD" in
    install)
        for a in "$@"; do
            case "$a" in
                --no-deps) INSTALL_NO_DEPS=1 ;;
                *)         INSTALL_FILE="$a" ;;
            esac
        done
        [ -z "$INSTALL_FILE" ] && print_help && exit 1
        install_from_pkg_or_source "$INSTALL_FILE"
        ;;
    install-bin)
        INSTALL_BIN=1
        for a in "$@"; do
            case "$a" in
                --no-deps) INSTALL_NO_DEPS=1 ;;
                *)         INSTALL_FILE="$a" ;;
            esac
        done
        [ -z "$INSTALL_FILE" ] && print_help && exit 1
        install_from_pkg_or_source "$INSTALL_FILE"
        ;;
    *)
        print_help
        exit 1
        ;;
esac
